// `pond detect FILE.mp4 … [--model ID] [--every S] [--pictures DIR] [--compute all|ane|gpu|cpu]`: runs a detection
// model over recordings, a frame every S seconds (1), and says how fast it ran and what it found (in Pond's terms,
// and the model's own); with --pictures, a few of the frames it found something in, boxes drawn. For trying a model
// (the one built in, or one added to the Models folder) on a camera's own footage. `pond detect models` lists them.
#if canImport(NVRMac)
import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import Detection
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DetectCommand {
    static func run(_ args: [String]) -> Int32 {
        var args = args
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i ... i + 1) }
            return args[i + 1]
        }
        if args == ["models"] {
            let models = ModelStore.all()
            if models.isEmpty { print("No models (built in: the app's Resources/Models; added: \(ModelStore.userFolder.path))") }
            for m in models {
                print("\(m.id)  \(m.manifest.name)  [\(m.manifest.license)]\(m.builtIn ? "  built in" : "")  \(m.url.path)")
            }
            return 0
        }
        let modelID = option("--model")
        let every = option("--every").flatMap(Double.init) ?? 1
        let picturesFolder = option("--pictures")
        let compute: Detector.Compute = switch option("--compute") {
        case "cpu": .cpu
        case "gpu": .gpu
        case "ane": .neuralEngine
        default: .all
        }
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("✗ pond detect FILE.mp4 … [--model ID] [--every S] [--pictures DIR] [--compute all|ane|gpu|cpu]; pond detect models\n".utf8))
            return 2
        }
        guard let model = ModelStore.choose(modelID) else {
            FileHandle.standardError.write(Data("✗ No model\(modelID.map { " \($0)" } ?? ""). See: pond detect models\n".utf8))
            return 1
        }
        let detector = Detector()
        let loadStart = Date()
        do {
            try detector.use(model, compute: compute)
        } catch {
            FileHandle.standardError.write(Data("✗ \(error.description)\n".utf8))
            return 1
        }
        print("\(model.manifest.name) [\(model.manifest.license)], loaded in \(milliseconds(Date().timeIntervalSince(loadStart))) ms")

        var times: [Double] = []
        var categories: [DetectedCategory: Int] = [:]
        var labels: [String: Int] = [:]
        var framesWith = 0, saved = 0
        if let picturesFolder { try? FileManager.default.createDirectory(atPath: picturesFolder, withIntermediateDirectories: true) }
        for path in args {
            let frames = Self.frames(of: URL(fileURLWithPath: path), every: every)
            for (time, picture) in frames {
                let started = Date()
                let found: [Detection]
                do {
                    found = try detector.detect(picture)
                } catch {
                    FileHandle.standardError.write(Data("✗ \(error.description)\n".utf8))
                    return 1
                }
                times.append(Date().timeIntervalSince(started))
                guard !found.isEmpty else { continue }
                framesWith += 1
                for d in found {
                    categories[d.category, default: 0] += 1
                    labels[d.label, default: 0] += 1
                }
                let words = found.map { "\($0.label) \(Int(($0.confidence * 100).rounded()))%" }.joined(separator: ", ")
                print(String(format: "  %@ %6.1f s  ", (path as NSString).lastPathComponent, time) + words)
                if let picturesFolder, saved < 12 {
                    let name = "\((path as NSString).lastPathComponent.replacingOccurrences(of: ".mp4", with: ""))-\(Int(time)).jpg"
                    Self.save(picture, found, to: (picturesFolder as NSString).appendingPathComponent(name))
                    saved += 1
                }
            }
        }
        guard !times.isEmpty else {
            print("No frames read.")
            return 1
        }
        let sorted = times.sorted()
        print("")
        print("\(times.count) frames, \(framesWith) with something: \(milliseconds(sorted.reduce(0, +) / Double(sorted.count))) ms a frame on average, \(milliseconds(sorted[sorted.count / 2])) median, \(milliseconds(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])) at the 95th percentile")
        print("found: " + DetectedCategory.allCases.compactMap { c in categories[c].map { "\(c.rawValue) \($0)" } }.joined(separator: ", "))
        print("labels: " + labels.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        return 0
    }

    static func milliseconds(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    /// The video's frames, one every `every` seconds, as pixel buffers.
    static func frames(of url: URL, every: Double) -> [(Double, CVPixelBuffer)] {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var frames: [(Double, CVPixelBuffer)] = []
        Task {
            frames = (try? await read(url, every: every)) ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return frames
    }

    static func read(_ url: URL, every: Double) async throws -> [(Double, CVPixelBuffer)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var frames: [(Double, CVPixelBuffer)] = []
        var next = 0.0
        while let sample = try await provider.next() {
            let time = sample.presentationTimeStamp.seconds
            guard time >= next else { continue }
            // (Taken out of the sample, which is only lent to the closure.)
            nonisolated(unsafe) var buffer: CVPixelBuffer?
            sample.withUnsafeSampleBuffer { buffer = CMSampleBufferGetImageBuffer($0) }
            if let picture = buffer {
                frames.append((time, picture))
                next = time + every
            }
        }
        return frames
    }

    /// The picture with its detections' boxes (coloured by category), as a JPEG.
    static func save(_ picture: CVPixelBuffer, _ found: [Detection], to path: String) {
        let image = CIImage(cvPixelBuffer: picture)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return }
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineWidth(max(2, CGFloat(width) / 400))
        for d in found {
            let colour: CGColor = switch d.category {
            case .person: CGColor(red: 1, green: 0.3, blue: 0.5, alpha: 1)
            case .vehicle: CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1)
            case .animal: CGColor(red: 1, green: 0.7, blue: 0.2, alpha: 1)
            case .package: CGColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 1)
            case .other: CGColor(gray: 0.9, alpha: 1)
            }
            context.setStrokeColor(colour)
            // (CoreGraphics's y runs up from the bottom.)
            context.stroke(CGRect(x: d.box.x * Double(width), y: (1 - d.box.y - d.box.height) * Double(height),
                                  width: d.box.width * Double(width), height: d.box.height * Double(height)))
        }
        guard let drawn = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, drawn, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
#endif
