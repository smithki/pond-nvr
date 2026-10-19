// Runs a detection model on pictures: through Vision (which scales the picture into the model's input, letterboxed,
// on the Neural Engine where it can), its answers read by the manifest's decoder. The model can be swapped while it
// runs (`use`): pictures already being looked at finish with the one they started with.
//
// Models are found by `ModelStore`: built into the app (Contents/Resources/Models), or added to Pond's Models folder
// (~/Library/Application Support/Pond/Models), each a Core ML `.mlpackage` (or `.mlmodelc`) or a Core AI `.aimodel`
// with its `.json` manifest beside it. A Core ML package is compiled once and kept compiled in the caches; a Core AI
// model is specialized for this Mac once, and kept by Core AI's own cache. What runs a model is a `ModelRunner`.
import CoreML
import CoreVideo
import Foundation
import Vision

public final class Detector: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case noModel(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .noModel(why), let .unreadable(why): why
            }
        }
    }

    /// Where it runs: everywhere it can (the Neural Engine first), or only on one.
    public enum Compute: Sendable { case all, neuralEngine, gpu, cpu }

    private let lock = NSLock()
    private var loaded: (info: ModelStore.Model, runner: any ModelRunner)?

    public init() {}

    /// The model in use now.
    public var model: ModelStore.Model? { lock.withLock { loaded?.info } }

    /// Loads `model` (by its kind: a Core ML model, or a Core AI one) and uses it from now on; the one before
    /// finishes what it's doing.
    public func use(_ model: ModelStore.Model, compute: Compute = .all) throws(Failure) {
        let runner: any ModelRunner
        do {
            switch model.kind {
            case .coreML: runner = try CoreMLRunner(model, compute: compute)
            case .coreAI: runner = try CoreAIRunner.load(model, compute: compute)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable("\(model.manifest.name) couldn\u{2019}t be loaded: \(error.localizedDescription)")
        }
        lock.withLock { loaded = (model, runner) }
    }

    /// What's in a picture (in the model's terms, put in Pond's), surest first.
    public func detect(_ picture: CVPixelBuffer) throws(Failure) -> [Detection] {
        guard let (info, runner) = lock.withLock({ loaded }) else { throw .noModel("no detection model is loaded") }
        let manifest = info.manifest
        let input = (width: Double(manifest.inputSize.first ?? 640), height: Double(manifest.inputSize.last ?? 640))
        let letterbox = Letterbox(image: (Double(CVPixelBufferGetWidth(picture)), Double(CVPixelBufferGetHeight(picture))),
                                  input: input)
        let answer = try runner.run(picture, input: (Int(input.width), Int(input.height)))
        return Self.decode(answer, manifest: manifest, labels: runner.labels, letterbox: letterbox, input: input)
    }

    /// A runner's answer read by the manifest's format.
    static func decode(_ answer: ModelAnswer, manifest: DetectionModelManifest, labels: [String], letterbox: Letterbox,
                       input: (width: Double, height: Double)) -> [Detection] {
        let minimum = manifest.minimumConfidence ?? 0.35
        switch answer {
        case let .objects(found):
            return found.filter { $0.confidence >= minimum }
        case let .tensors(tensors):
            switch manifest.output {
            case .vision:
                return []
            case .endToEnd:
                guard let t = tensors.first, t.shape.count >= 2 else { return [] }
                return DetectionDecoder.endToEnd(t.values, count: t.shape[t.shape.count - 2], letterbox: letterbox, labels: labels,
                                                 manifest: manifest, minimum: minimum)
            case .yoloRaw:
                guard let t = tensors.first, t.shape.count >= 2 else { return [] }
                return DetectionDecoder.yoloRaw(t.values, classes: t.shape[t.shape.count - 2] - 4, anchors: t.shape[t.shape.count - 1],
                                                letterbox: letterbox, labels: labels, manifest: manifest, minimum: minimum)
            case .detr:
                guard let boxes = tensors.first(where: { $0.shape.last == 4 }),
                      let logits = tensors.first(where: { $0.name != boxes.name }), boxes.shape.count >= 2,
                      let classes = logits.shape.last else { return [] }
                return DetectionDecoder.detr(boxes: boxes.values, logits: logits.values, queries: boxes.shape[boxes.shape.count - 2],
                                             classes: classes, letterbox: letterbox, input: input, labels: labels,
                                             manifest: manifest, minimum: minimum)
            }
        }
    }

    /// The class names a model carries (Ultralytics writes them as "names": "{0: 'person', 1: 'bicycle', …}").
    static func parseNames(_ text: String) -> [String] {
        var names: [Int: String] = [:]
        let pattern = /(\d+)\s*:\s*['"]([^'"]*)['"]/
        for match in text.matches(of: pattern) {
            if let index = Int(match.1) { names[index] = String(match.2) }
        }
        guard let last = names.keys.max() else { return [] }
        return (0 ... last).map { names[$0] ?? "class \($0)" }
    }
}

// MARK: - Runners

/// A model's answer: its outputs as arrays (for the manifest's decoder), or objects already (a model with its own
/// suppression, through Vision).
public enum ModelAnswer: Sendable {
    case tensors([Tensor])
    case objects([Detection])
}

public struct Tensor: Sendable {
    public var name: String
    public var shape: [Int]
    public var values: [Float]
}

/// What runs a model on a picture: Core ML (through Vision) or Core AI. Another runtime is another of these; the
/// manifest, the decoders and all that follows stay as they are.
protocol ModelRunner: Sendable {
    /// Its classes by number (the manifest's, or the model's own).
    var labels: [String] { get }
    /// The picture, letterboxed into the model's input (`input`, in pixels), run.
    func run(_ picture: CVPixelBuffer, input: (width: Int, height: Int)) throws(Detector.Failure) -> ModelAnswer
}

/// A Core ML model, through Vision (which letterboxes the picture into its input, and converts its colours).
final class CoreMLRunner: ModelRunner, @unchecked Sendable {
    let model: VNCoreMLModel
    let labels: [String]
    let manifest: DetectionModelManifest

    init(_ info: ModelStore.Model, compute: Detector.Compute) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = switch compute {
        case .all: .all
        case .neuralEngine: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        case .cpu: .cpuOnly
        }
        let ml = try MLModel(contentsOf: try ModelStore.compiled(info), configuration: configuration)
        model = try VNCoreMLModel(for: ml)
        manifest = info.manifest
        labels = info.manifest.labels ?? Self.labels(in: ml.modelDescription)
    }

    func run(_ picture: CVPixelBuffer, input: (width: Int, height: Int)) throws(Detector.Failure) -> ModelAnswer {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        do {
            try VNImageRequestHandler(cvPixelBuffer: picture, options: [:]).perform([request])
        } catch {
            throw .unreadable("the model couldn\u{2019}t look at the picture: \(error.localizedDescription)")
        }
        let results = request.results ?? []
        if manifest.output == .vision {
            return .objects(results.compactMap { $0 as? VNRecognizedObjectObservation }.compactMap { o in
                guard let top = o.labels.first else { return nil }
                // Vision's boxes are fractions from the bottom left.
                let b = o.boundingBox
                return Detection(label: top.identifier, category: manifest.category(of: top.identifier), confidence: Double(top.confidence),
                                 box: .init(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            })
        }
        return .tensors(results.compactMap { $0 as? VNCoreMLFeatureValueObservation }.compactMap { o in
            o.featureValue.multiArrayValue.map {
                Tensor(name: o.featureName, shape: $0.shape.map(\.intValue), values: Self.floats($0))
            }
        })
    }

    /// Its values as Float, whatever it holds them as.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let n = array.count
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(n)) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.prefix(n).map(Float.init) }
        case .double:
            return array.withUnsafeBufferPointer(ofType: Double.self) { $0.prefix(n).map(Float.init) }
        default:
            return (0 ..< n).map { array[$0].floatValue }
        }
    }

    static func labels(in description: MLModelDescription) -> [String] {
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        if let names = metadata["names"] { return Detector.parseNames(names) }
        if let labels = description.classLabels as? [String] { return labels }
        return []
    }
}

/// The models there are: built into the app, and added to Pond's Models folder.
public enum ModelStore {
    public struct Model: Equatable, Sendable, Identifiable {
        /// The package (or compiled model) file.
        public var url: URL
        public var manifest: DetectionModelManifest
        public var builtIn: Bool
        public var id: String { url.deletingPathExtension().lastPathComponent }

        /// What runs it: Core ML (`.mlpackage`, `.mlmodelc`, `.mlmodel`) or Core AI (`.aimodel`).
        public enum Kind: Sendable { case coreML, coreAI }
        public var kind: Kind { url.pathExtension == "aimodel" ? .coreAI : .coreML }
    }

    /// Where models are added: Pond's Models folder.
    public static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pond/Models")
    }

    /// The built-in ones: the app's resources (pond runs from Pond.app/Contents/MacOS), or `POND_MODELS` (a
    /// folder, for development: the repository's models/).
    static var builtInFolders: [URL] {
        var folders = [Bundle.main.resourceURL?.appendingPathComponent("Models")].compactMap { $0 }
        if let dev = ProcessInfo.processInfo.environment["POND_MODELS"] { folders.append(URL(fileURLWithPath: dev)) }
        return folders
    }

    /// Every model found, built-in first; one without a manifest is left out.
    public static func all() -> [Model] {
        builtInFolders.flatMap { models(in: $0, builtIn: true) } + models(in: userFolder, builtIn: false)
    }

    /// The model to use: the one chosen (by id) if there is one, else the first built in.
    public static func choose(_ id: String?) -> Model? {
        let models = all()
        return models.first { $0.id == id } ?? models.first { $0.builtIn } ?? models.first
    }

    static func models(in folder: URL, builtIn: Bool) -> [Model] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { name -> Model? in
            let url = folder.appendingPathComponent(name)
            guard ["mlpackage", "mlmodelc", "mlmodel", "aimodel"].contains(url.pathExtension) else { return nil }
            let manifestURL = url.deletingPathExtension().appendingPathExtension("json")
            guard let data = FileManager.default.contents(atPath: manifestURL.path),
                  let manifest = try? JSONDecoder().decode(DetectionModelManifest.self, from: data) else { return nil }
            return Model(url: url, manifest: manifest, builtIn: builtIn)
        }
    }

    /// The model compiled (kept in the caches, by its file's name and date, so it's compiled once).
    static func compiled(_ model: Model) throws -> URL {
        if model.url.pathExtension == "mlmodelc" { return model.url }
        let date = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pond/Models", isDirectory: true)
        let kept = caches.appendingPathComponent("\(model.id)-\(Int(date)).mlmodelc")
        if FileManager.default.fileExists(atPath: kept.path) { return kept }
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let made = try MLModel.compileModel(at: model.url)
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: made, to: kept)
        return kept
    }
}
