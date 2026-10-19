// A Core AI model (`.aimodel`, macOS 27's own format for on-device models): specialized for this Mac once (Core AI
// keeps it in its cache), its first function run on each picture. Core AI has no Vision of its own, so the picture
// is fitted into the model's input here: letterboxed (scaled to fit, centred, the rest black) by Video Toolbox,
// then given as the pixel buffer an image input takes, or as RGB in 0…1, channels first, for an array input (as
// Ultralytics' models take it). Each output comes back as an array, read by the manifest's decoder.
import CoreAI
import CoreVideo
import Foundation
import VideoToolbox

final class CoreAIRunner: ModelRunner, @unchecked Sendable {
    let function: InferenceFunction
    let inputName: String
    let input: InferenceValue.Descriptor
    let outputNames: [String]
    let labels: [String]
    private let lock = NSLock()
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(function: InferenceFunction, inputName: String, input: InferenceValue.Descriptor, outputNames: [String], labels: [String]) {
        self.function = function
        self.inputName = inputName
        self.input = input
        self.outputNames = outputNames
        self.labels = labels
    }

    /// The model specialized (on the compute asked for) and its first function loaded.
    static func load(_ info: ModelStore.Model, compute: Detector.Compute) throws -> CoreAIRunner {
        let options: SpecializationOptions = switch compute {
        case .all: .default
        case .neuralEngine: SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        case .gpu: SpecializationOptions(preferredComputeUnitKind: .gpu)
        case .cpu: .cpuOnly
        }
        let model = try blocking { try await AIModel.specialize(contentsOf: info.url, options: options) }
        guard let name = model.functionNames.first, let descriptor = model.functionDescriptor(for: name),
              let function = try model.loadFunction(named: name),
              let inputName = descriptor.inputNames.first, let input = descriptor.inputDescriptor(of: inputName) else {
            throw Detector.Failure.unreadable("\(info.manifest.name) has no function to run")
        }
        // (A Core AI model's class names aren't known to be in it: its manifest gives them.)
        return CoreAIRunner(function: function, inputName: inputName, input: input, outputNames: descriptor.outputNames,
                            labels: info.manifest.labels ?? [])
    }

    func run(_ picture: CVPixelBuffer, input size: (width: Int, height: Int)) throws(Detector.Failure) -> ModelAnswer {
        let format: OSType
        if case let .image(image) = input { format = image.pixelFormatType } else { format = kCVPixelFormatType_32BGRA }
        guard let fitted = letterboxed(picture, width: size.width, height: size.height, format: format) else {
            throw .unreadable("the picture couldn\u{2019}t be fitted to the model")
        }
        let function = self.function, inputName = self.inputName, outputNames = self.outputNames
        // (Handed to the model's run alone: not shared.)
        nonisolated(unsafe) let picture = fitted
        let tensors: [Tensor]
        do {
            switch input {
            case .image:
                tensors = try blocking {
                    let buffer = CVMutablePixelBuffer(unsafeBuffer: picture)
                    var inputs = InferenceFunction.Inputs()
                    inputs.insert(buffer, for: inputName)
                    var outputs = try await function.run(inputs: inputs)
                    return Self.tensors(&outputs, names: outputNames)
                }
            case let .ndArray(descriptor):
                let array = Self.rgbPlanes(picture, shape: descriptor.shape)
                tensors = try blocking {
                    var outputs = try await function.run(inputs: [inputName: array])
                    return Self.tensors(&outputs, names: outputNames)
                }
            @unknown default:
                throw Detector.Failure.unreadable("the model takes an input Pond doesn\u{2019}t know")
            }
        } catch {
            throw .unreadable("the model couldn\u{2019}t look at the picture: \(error.localizedDescription)")
        }
        return .tensors(tensors)
    }

    /// Each output, as an array of Float.
    static func tensors(_ outputs: inout InferenceFunction.Outputs, names: [String]) -> [Tensor] {
        names.compactMap { name -> Tensor? in
            guard let value = outputs.remove(name), let array = value.ndArray else { return nil }
            return Tensor(name: name, shape: array.shape, values: floats(array))
        }
    }

    static func floats(_ array: NDArray) -> [Float] {
        let count = array.shape.reduce(1, *)
        switch array.scalarType {
        case .float16:
            return array.view(as: Float16.self).withUnsafePointer { p, _, _ in UnsafeBufferPointer(start: p, count: count).map(Float.init) }
        case .float32:
            return array.view(as: Float.self).withUnsafePointer { p, _, _ in Array(UnsafeBufferPointer(start: p, count: count)) }
        default:
            return []
        }
    }

    /// The picture as RGB in 0…1, channels first ([1, 3, height, width]), from its 32BGRA.
    static func rgbPlanes(_ picture: CVPixelBuffer, shape: [Int]) -> NDArray {
        let height = shape.count >= 2 ? shape[shape.count - 2] : CVPixelBufferGetHeight(picture)
        let width = shape.last ?? CVPixelBufferGetWidth(picture)
        var values = [Float](repeating: 0, count: 3 * width * height)
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(picture) {
            let row = CVPixelBufferGetBytesPerRow(picture)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let plane = width * height
            for y in 0 ..< min(height, CVPixelBufferGetHeight(picture)) {
                for x in 0 ..< min(width, CVPixelBufferGetWidth(picture)) {
                    let p = bytes + y * row + x * 4   // B, G, R, A
                    let i = y * width + x
                    values[i] = Float(p[2]) / 255
                    values[plane + i] = Float(p[1]) / 255
                    values[2 * plane + i] = Float(p[0]) / 255
                }
            }
        }
        return NDArray(scalars: values, shape: shape.isEmpty ? [1, 3, height, width] : shape)
    }

    /// Scaled to fit `width`×`height`, centred, the rest black (as Vision fits pictures for Core ML).
    func letterboxed(_ picture: CVPixelBuffer, width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.withLock {
            if transfer == nil {
                var session: VTPixelTransferSession?
                VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
                if let session {
                    VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
                }
                transfer = session
            }
            if pool == nil {
                let attributes = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                  kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                  kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
                CVPixelBufferPoolCreate(nil, nil, attributes, &pool)
            }
            guard let transfer, let pool else { return nil }
            var fitted: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &fitted) == kCVReturnSuccess, let fitted,
                  VTPixelTransferSessionTransferImage(transfer, from: picture, to: fitted) == noErr else { return nil }
            return fitted
        }
    }
}

/// Async work waited for from a plain thread (detection runs on the recorder's and pond detect's own threads).
func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, any Error>?
    Task.detached {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result!.get()
}
