// Pictures and words as embeddings in one space (SigLIP 2, Google's, Apache-2.0): a picture's and a phrase's, compared
// with a dot product, say how well they go together, and SigLIP's own calibration turns that into a probability.
// For search: an event's picture is embedded once, as it's kept; a question's words, as it's asked. The models are
// made from Google's by scripts/convert-siglip.py, and built into the app (Contents/Resources/Search) when they're
// there; without them, there are no embeddings, and search goes by what was found and the descriptions.
import CoreGraphics
import CoreML
import Foundation

public final class SigLIP: @unchecked Sendable {
    public struct Manifest: Codable, Sendable {
        public var name: String
        public var imageSize: Int
        public var tokens: Int
        public var dimensions: Int
        public var padID: Int32
        public var lowercase: Bool
        public var logitScale: Double
        public var logitBias: Double
        public var references: [Reference]?
        public var pictureReference: PictureReference?

        /// A phrase, its ids and its embedding as the model's own code made them (for tests).
        public struct Reference: Codable, Sendable {
            public var text: String
            public var ids: [Int32]
            public var embedding: [Float]
        }

        /// A picture anyone can make again (`kind`: "gradient", red across, green down, blue at 128, at the model's
        /// size) and its embedding as the model's own code made it (for tests).
        public struct PictureReference: Codable, Sendable {
            public var kind: String
            public var embedding: [Float]
            /// As the converted (quantized) encoder makes it.
            public var converted: [Float]?
        }
    }

    public let manifest: Manifest
    let tokenizer: BPETokenizer
    /// Either side may be left out: the service embeds pictures only, the app words only.
    let image: MLModel?
    let text: MLModel?
    /// The models are used one call at a time.
    private let lock = NSLock()

    public enum Failure: Error {
        case missing(String)
        case noEmbedding
    }

    /// The folder the models are in, when there are any: the app's Search resources (pond runs from Pond
    /// NVR.app/Contents/MacOS), or `POND_SEARCH_MODELS` (a folder, for development: the repository's models/search).
    public static var builtIn: URL? {
        let folders = [ProcessInfo.processInfo.environment["POND_SEARCH_MODELS"].map { URL(fileURLWithPath: $0) },
                       Bundle.main.resourceURL?.appendingPathComponent("Search")].compactMap { $0 }
        return folders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("siglip2.json").path) }
    }

    /// From a folder with siglip2.json, siglip2-tokenizer.json and the two models (compiled .mlmodelc, or
    /// .mlpackage, compiled now); the picture one only if `pictures`, the words one only if `words`.
    ///
    /// Pictures on the Neural Engine: many of them, in the service's background, where readying the model for it
    /// (some seconds, the first time a program loads it after an install or update; remembered by that program
    /// only) costs no one a wait. Words on the CPU: a question at a time, a few milliseconds each, and loaded at
    /// once (the Neural Engine's readying, again in each program, would be a first search's wait).
    public init(folder: URL, pictures: Bool = true, words: Bool = true) throws {
        let manifestURL = folder.appendingPathComponent("siglip2.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.missing(manifestURL.path) }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
        tokenizer = try BPETokenizer(contentsOf: folder.appendingPathComponent("siglip2-tokenizer.json"))
        image = pictures ? try Self.model(folder, "siglip2-image", on: .all) : nil
        text = words ? try Self.model(folder, "siglip2-text", on: .cpuOnly) : nil
    }

    static func model(_ folder: URL, _ name: String, on units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let compiled = folder.appendingPathComponent(name + ".mlmodelc")
        let package = folder.appendingPathComponent(name + ".mlpackage")
        func modified(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        // Compiled already (and not older than the package, if there's one: made again since).
        if let built = modified(compiled), modified(package).map({ $0 <= built }) ?? true {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        guard FileManager.default.fileExists(atPath: package.path) else { throw Failure.missing(package.path) }
        try? FileManager.default.removeItem(at: compiled)
        // Compiled once and kept beside it: Core ML readies a model for the Neural Engine the first time it's loaded
        // from a place (some seconds), and remembers it after (for that program); compiled somewhere new each time,
        // it never would.
        let made = try MLModel.compileModel(at: package)
        if (try? FileManager.default.moveItem(at: made, to: compiled)) != nil {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        return try MLModel(contentsOf: made, configuration: configuration)
    }

    /// The ids the text encoder takes for `phrase`.
    public func ids(_ phrase: String) -> [Int32] {
        tokenizer.ids(manifest.lowercase ? phrase.lowercased() : phrase, length: manifest.tokens, pad: manifest.padID)
    }

    /// A phrase's embedding (unit length).
    public func embed(_ phrase: String) throws -> [Float] {
        let ids = ids(phrase)
        let input = try MLMultiArray(shape: [1, NSNumber(value: manifest.tokens)], dataType: .int32)
        for (i, id) in ids.enumerated() { input[i] = NSNumber(value: id) }
        guard let text else { throw Failure.noEmbedding }
        return try lock.withLock {
            try Self.embedding(text.prediction(from: MLDictionaryFeatureProvider(dictionary: ["ids": input])))
        }
    }

    /// A picture's embedding (unit length): the picture squashed to the model's size, as SigLIP 2 takes it.
    public func embed(_ picture: CGImage) throws -> [Float] {
        guard let image, let constraint = image.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw Failure.noEmbedding }
        let value = try MLFeatureValue(cgImage: picture, constraint: constraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOptionScaleFill])
        return try lock.withLock {
            try Self.embedding(image.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value])))
        }
    }

    static func embedding(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue else { throw Failure.noEmbedding }
        return (0 ..< array.count).map { array[$0].floatValue }
    }

    /// How well two embeddings go together: their dot product (both unit length).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        for i in 0 ..< min(a.count, b.count) { sum += a[i] * b[i] }
        return Double(sum)
    }

    /// The chance a picture and a phrase this similar go together, as SigLIP was trained to say.
    public func probability(_ similarity: Double) -> Double {
        1 / (1 + exp(-(manifest.logitScale * similarity + manifest.logitBias)))
    }
}

/// (Vision's crop-and-scale option for squashing, by its raw value: Core ML's image options take it, and importing
/// Vision for one constant isn't worth it.)
let VNImageCropAndScaleOptionScaleFill = NSNumber(value: 2)
