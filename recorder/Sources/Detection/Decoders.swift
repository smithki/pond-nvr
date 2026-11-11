// A model's answers (its output arrays) read as detections, for each output format a manifest can name. Plain
// Swift on flat arrays, so it's the same whatever runs the model, and tested without one. Boxes come out as
// fractions of the original picture: the model saw it letterboxed (scaled to fit its input, centred, the rest
// padding), which `Letterbox` undoes.
import Foundation

/// How a picture was fitted into the model's input: scaled by `scale`, then offset by the padding.
public struct Letterbox: Equatable, Sendable {
    public var scale: Double
    public var padX: Double, padY: Double
    public var imageWidth: Double, imageHeight: Double

    public init(image: (width: Double, height: Double), input: (width: Double, height: Double)) {
        scale = min(input.width / image.width, input.height / image.height)
        padX = (input.width - image.width * scale) / 2
        padY = (input.height - image.height * scale) / 2
        imageWidth = image.width
        imageHeight = image.height
    }

    /// A box in the model's input pixels (left, top, right, bottom) as a fraction of the picture, kept inside it.
    public func box(left: Double, top: Double, right: Double, bottom: Double) -> Detection.Box {
        func x(_ v: Double) -> Double { min(1, max(0, (v - padX) / scale / imageWidth)) }
        func y(_ v: Double) -> Double { min(1, max(0, (v - padY) / scale / imageHeight)) }
        let l = x(left), t = y(top), r = x(right), b = y(bottom)
        return Detection.Box(x: l, y: t, width: max(0, r - l), height: max(0, b - t))
    }
}

public enum DetectionDecoder {
    /// YOLO26's final boxes: `values` is [count × 6], each x1, y1, x2, y2, score, class.
    public static func endToEnd(_ values: [Float], count: Int, letterbox: Letterbox, labels: [String],
                                manifest: DetectionModelManifest, minimum: Double) -> [Detection] {
        var found: [Detection] = []
        for i in 0 ..< count where i * 6 + 5 < values.count {
            let row = values[i * 6 ..< i * 6 + 6].map(Double.init)
            let score = row[4]
            guard score >= minimum else { continue }
            let label = Self.label(Int(row[5]), labels)
            found.append(Detection(label: label, category: manifest.category(of: label), confidence: score,
                                   box: letterbox.box(left: row[0], top: row[1], right: row[2], bottom: row[3])))
        }
        return found.sorted { $0.confidence > $1.confidence }
    }

    /// Raw YOLO candidates, channel first: `values` is [(4 + classes) × anchors]; the best class of each, then
    /// overlapping boxes of a class suppressed.
    public static func yoloRaw(_ values: [Float], classes: Int, anchors: Int, letterbox: Letterbox, labels: [String],
                               manifest: DetectionModelManifest, minimum: Double, overlap: Double = 0.45) -> [Detection] {
        guard values.count >= (4 + classes) * anchors else { return [] }
        var candidates: [Detection] = []
        for a in 0 ..< anchors {
            var best = 0, bestScore: Float = 0
            for c in 0 ..< classes {
                let s = values[(4 + c) * anchors + a]
                if s > bestScore { bestScore = s; best = c }
            }
            guard Double(bestScore) >= minimum else { continue }
            let cx = Double(values[a]), cy = Double(values[anchors + a])
            let w = Double(values[2 * anchors + a]), h = Double(values[3 * anchors + a])
            let label = Self.label(best, labels)
            candidates.append(Detection(label: label, category: manifest.category(of: label), confidence: Double(bestScore),
                                        box: letterbox.box(left: cx - w / 2, top: cy - h / 2, right: cx + w / 2, bottom: cy + h / 2)))
        }
        return suppress(candidates, overlap: overlap)
    }

    /// DETR-style queries: boxes [queries × 4] (centre x, centre y, width, height, fractions of the input) and
    /// logits [queries × classes]; each query's best class, its score a sigmoid.
    public static func detr(boxes: [Float], logits: [Float], queries: Int, classes: Int, letterbox: Letterbox,
                            input: (width: Double, height: Double), labels: [String], manifest: DetectionModelManifest,
                            minimum: Double) -> [Detection] {
        var found: [Detection] = []
        for q in 0 ..< queries where q * 4 + 3 < boxes.count {
            var best = 0, bestLogit = -Float.infinity
            for c in 0 ..< classes where q * classes + c < logits.count {
                let l = logits[q * classes + c]
                if l > bestLogit { bestLogit = l; best = c }
            }
            let score = 1 / (1 + exp(-Double(bestLogit)))
            guard score >= minimum else { continue }
            let cx = Double(boxes[q * 4]) * input.width, cy = Double(boxes[q * 4 + 1]) * input.height
            let w = Double(boxes[q * 4 + 2]) * input.width, h = Double(boxes[q * 4 + 3]) * input.height
            let label = Self.label(best, labels)
            found.append(Detection(label: label, category: manifest.category(of: label), confidence: score,
                                   box: letterbox.box(left: cx - w / 2, top: cy - h / 2, right: cx + w / 2, bottom: cy + h / 2)))
        }
        return suppress(found, overlap: 0.7)
    }

    /// Overlapping boxes of the same label suppressed: the surest kept (non-maximum suppression).
    public static func suppress(_ detections: [Detection], overlap: Double) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence })
        where !kept.contains(where: { $0.label == d.label && $0.box.overlap(d.box) > overlap }) {
            kept.append(d)
        }
        return kept
    }

    static func label(_ index: Int, _ labels: [String]) -> String {
        labels.indices.contains(index) ? labels[index] : "class \(index)"
    }
}
