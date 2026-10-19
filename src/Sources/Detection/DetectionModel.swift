// What a detection model is, as Pond takes one: a Core ML model with a small manifest beside it saying what it
// finds and how to read its answers. Any model can be used this way: the one built in (Ultralytics YOLO26), or one
// added to the Models folder (another YOLO, RF-DETR, D-FINE, one fitted to a home's own scenes), and swapped while
// Pond runs. What a model finds is put in Pond's own terms: a person, a vehicle, an animal, a package.
import Foundation

/// What Pond cares that something is. An item is something a person carries and may leave behind (a bag, a
/// suitcase): an event when it's put down and stays. A ring isn't seen by a model: it's a doorbell's button
/// pressed, an event of its own (with the picture at that moment).
public enum DetectedCategory: String, Codable, Sendable, CaseIterable, Comparable {
    case person, vehicle, animal, package, item, ring, other

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// One thing found in a picture: what (the model's word, and Pond's category), how sure, and where, as a
/// fraction of the picture (x and y from the top left).
public struct Detection: Equatable, Sendable, Codable {
    public var label: String
    public var category: DetectedCategory
    public var confidence: Double
    public var box: Box

    public struct Box: Equatable, Sendable, Codable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var area: Double { max(0, width) * max(0, height) }

        /// The share of the two that overlap (intersection over union).
        public func overlap(_ other: Box) -> Double {
            let left = max(x, other.x), top = max(y, other.y)
            let right = min(x + width, other.x + other.width), bottom = min(y + height, other.y + other.height)
            let shared = max(0, right - left) * max(0, bottom - top)
            let union = area + other.area - shared
            return union > 0 ? shared / union : 0
        }
    }

    public init(label: String, category: DetectedCategory, confidence: Double, box: Box) {
        self.label = label
        self.category = category
        self.confidence = confidence
        self.box = box
    }
}

/// A model's manifest (`<model>.json` beside `<model>.mlpackage`): what it is, its terms, how to read it.
public struct DetectionModelManifest: Codable, Equatable, Sendable {
    public var name: String
    /// Its terms, as its maker gives them ("AGPL-3.0", "Apache-2.0"), shown where it's chosen.
    public var license: String
    public var source: String?
    /// The picture size it takes (width, height), letterboxed to it.
    public var inputSize: [Int]
    public var output: OutputFormat
    /// Its classes by number; nil: read from the model's own metadata (Ultralytics writes them as "names").
    public var labels: [String]?
    /// Pond's category for each of its labels, beyond the common ones (`DetectedCategory.forLabel`).
    public var categories: [String: DetectedCategory]?
    /// Below this, a detection is let go.
    public var minimumConfidence: Double?

    public enum OutputFormat: String, Codable, Sendable {
        /// Final boxes, no suppression needed: [1, N, 6] of x1, y1, x2, y2 (input pixels), score, class
        /// (Ultralytics YOLO26, and YOLOv10).
        case endToEnd = "end-to-end"
        /// Raw candidates: [1, 4 + classes, anchors] of centre x, centre y, width, height (input pixels) and each
        /// class's score; Pond suppresses the overlaps (YOLOv8, YOLO11, YOLOv9 exported without NMS).
        case yoloRaw = "yolo-raw"
        /// A model with its own suppression in the Core ML pipeline: Vision gives its objects as they are
        /// (Ultralytics exports with `nms=True`, Create ML's object detectors).
        case vision
        /// Queries: boxes [1, Q, 4] (centre x, centre y, width, height as fractions) and logits [1, Q, classes],
        /// each class's score a sigmoid (RF-DETR, D-FINE, RT-DETR).
        case detr
    }

    public init(name: String, license: String, source: String? = nil, inputSize: [Int], output: OutputFormat,
                labels: [String]? = nil, categories: [String: DetectedCategory]? = nil, minimumConfidence: Double? = nil) {
        self.name = name
        self.license = license
        self.source = source
        self.inputSize = inputSize
        self.output = output
        self.labels = labels
        self.categories = categories
        self.minimumConfidence = minimumConfidence
    }

    public func category(of label: String) -> DetectedCategory {
        categories?[label] ?? DetectedCategory.forLabel(label)
    }
}

extension DetectedCategory {
    /// The usual labels (COCO's, which most models are trained on) in Pond's terms.
    public static func forLabel(_ label: String) -> DetectedCategory {
        switch label.lowercased() {
        case "person", "people", "pedestrian", "face": .person
        case "car", "truck", "bus", "motorcycle", "motorbike", "bicycle", "bike", "van", "vehicle", "train", "boat": .vehicle
        case "dog", "cat", "bird", "horse", "sheep", "cow", "bear", "deer", "animal", "fox", "raccoon", "squirrel": .animal
        case "package", "parcel", "box": .package
        case "backpack", "handbag", "suitcase", "umbrella", "bag", "luggage": .item
        default: .other
        }
    }
}
