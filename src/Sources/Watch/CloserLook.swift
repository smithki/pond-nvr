// A closer look where something moves: the model sees the whole picture squeezed to its input (640×640), so
// something small in it (a cat across the room, a person at the end of the drive) is a few dozen pixels, too few
// to be sure of. Where the motion gate saw movement, the part of the picture around it, at full resolution (the
// main stream's, when it's at hand), is given to the model as well: a close-up of what moved. What it finds there
// is put back in the whole picture's terms and merged with the whole picture's findings.
import CoreImage
import CoreVideo
import Detection
import Foundation

public enum CloserLook {
    /// A crop is at least this many pixels a side (the model's input: smaller would only be enlarged).
    public static let minimumSide = 640.0
    /// Moving areas this much of the picture (wide or high) are seen well enough whole.
    public static let largeArea = 0.5
    /// Room around what moved, on each side, as a share of its size.
    public static let margin = 0.35

    /// The moving areas worth a closer look, in fractions of the picture: the moving cells, joined where they
    /// touch, the biggest first, at most `limit`, leaving out ones that are large already.
    public static func areas(_ mask: MotionMask, limit: Int = 2) -> [CGRect] {
        var left = mask.cells
        var groups: [Set<Int>] = []
        while let start = left.first {
            var group: Set<Int> = [start]
            var queue = [start]
            left.remove(start)
            while let cell = queue.popLast() {
                let row = cell / mask.columns, column = cell % mask.columns
                for (r, c) in [(row - 1, column), (row + 1, column), (row, column - 1), (row, column + 1),
                               (row - 1, column - 1), (row - 1, column + 1), (row + 1, column - 1), (row + 1, column + 1)]
                    where r >= 0 && r < mask.rows && c >= 0 && c < mask.columns {
                    let next = r * mask.columns + c
                    if left.remove(next) != nil {
                        group.insert(next)
                        queue.append(next)
                    }
                }
            }
            groups.append(group)
        }
        return groups.sorted { $0.count > $1.count }.compactMap { group -> CGRect? in
            let rows = group.map { $0 / mask.columns }, columns = group.map { $0 % mask.columns }
            let area = CGRect(x: Double(columns.min()!) / Double(mask.columns), y: Double(rows.min()!) / Double(mask.rows),
                              width: Double(columns.max()! - columns.min()! + 1) / Double(mask.columns),
                              height: Double(rows.max()! - rows.min()! + 1) / Double(mask.rows))
            return area.width > largeArea || area.height > largeArea ? nil : area
        }.prefix(limit).map { $0 }
    }

    /// The crop for an area (fractions) of a picture `width`×`height`, in pixels from the top left: the area and
    /// some room around it, square, at least `minimumSide` (or as much of the picture as there is), within the
    /// picture. Nil when it would be most of the picture anyway.
    public static func crop(_ area: CGRect, width: Int, height: Int) -> CGRect? {
        let w = Double(width), h = Double(height)
        let needed = max(area.width * w, area.height * h) * (1 + 2 * margin)
        let side = min(max(needed, minimumSide), w, h)
        // Half the picture or more: no closer than the whole.
        guard side * side < 0.5 * w * h else { return nil }
        let x = min(max(0, area.midX * w - side / 2), w - side)
        let y = min(max(0, area.midY * h - side / 2), h - side)
        return CGRect(x: x.rounded(), y: y.rounded(), width: side.rounded(), height: side.rounded())
    }

    /// That part of a picture, as a picture of its own (32BGRA).
    public static func picture(_ buffer: CVPixelBuffer, cropped rect: CGRect, context: CIContext) -> CVPixelBuffer? {
        let height = Double(CVPixelBufferGetHeight(buffer))
        // (Core Image's y runs up from the bottom.)
        let flipped = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: flipped)
            .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        var out: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(rect.width), Int(rect.height), kCVPixelFormatType_32BGRA, attributes, &out) == kCVReturnSuccess,
              let out else { return nil }
        context.render(image, to: out)
        return out
    }

    /// Found in a crop, put in the whole picture's terms.
    public static func mapped(_ found: [Detection], from crop: CGRect, width: Int, height: Int) -> [Detection] {
        let w = Double(width), h = Double(height)
        return found.map { d in
            var d = d
            d.box = Detection.Box(x: (crop.minX + d.box.x * crop.width) / w, y: (crop.minY + d.box.y * crop.height) / h,
                                  width: d.box.width * crop.width / w, height: d.box.height * crop.height / h)
            return d
        }
    }

    /// The whole picture's findings, and the closer looks' at what moved (in `closer`, the same view at a higher
    /// resolution, if there is one; else in the picture itself), duplicates merged. Nil if the model failed.
    public static func look(_ detect: (CVPixelBuffer) -> [Detection]?, whole: CVPixelBuffer, closer: CVPixelBuffer?,
                            mask: MotionMask, context: CIContext) -> [Detection]? {
        guard var found = detect(whole) else { return nil }
        let source = closer ?? whole
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        for area in areas(mask) {
            guard let rect = crop(area, width: width, height: height),
                  let part = picture(source, cropped: rect, context: context),
                  let near = detect(part) else { continue }
            found += mapped(near, from: rect, width: width, height: height)
        }
        return Duplicates.merged(found)
    }
}
