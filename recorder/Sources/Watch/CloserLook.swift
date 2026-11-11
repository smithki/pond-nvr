// A closer look where something moves: the model sees the whole picture squeezed to its input (640×640), so
// something small in it (a cat across the room, a person at the end of the drive) is a few dozen pixels, too few
// to be sure of. Where the motion gate saw movement, the part of the picture around it, at full resolution (the
// main stream's, when it's at hand), is given to the model as well: a close-up of what moved. What it finds there
// is put back in the whole picture's terms and merged with the whole picture's findings.
import CoreGraphics
import CoreVideo
import Detection
import Foundation

public enum CloserLook {
    /// How many closer looks there were (detection with a main-stream picture), and main streams opened for them,
    /// since last asked: for the hourly line that says how hard they've been worked (see VideoMemoryGuard).
    public enum Count {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var looks = 0, taps = 0

        static func looked() { lock.withLock { looks += 1 } }
        static func opened() { lock.withLock { taps += 1 } }

        /// The counts since last asked (and from now, none).
        public static func take() -> (looks: Int, taps: Int) {
            lock.withLock {
                defer { looks = 0; taps = 0 }
                return (looks, taps)
            }
        }
    }

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

    /// That part of a picture (32BGRA, or the decoder's 4:2:0), as a picture of its own in the same format: its
    /// rows copied out, so the decoder's picture is let go as soon as this returns. (Through Core Image, the
    /// decoder's pictures were kept by its cache of what it had drawn from, and the decoder made new ones for every
    /// look: the main stream's, 14–19 MB each, a few a second while something moved, until the Mac ran out of
    /// memory.) For 4:2:0, the crop's corner and sides are made even (its colour is one sample per 2×2 pixels).
    public static func picture(_ buffer: CVPixelBuffer, cropped rect: CGRect) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let biplanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard format == kCVPixelFormatType_32BGRA || biplanar else { return nil }
        let even = biplanar ? ~1 : ~0
        let x = Int(rect.minX) & even, y = Int(rect.minY) & even
        let width = Int(rect.width) & even, height = Int(rect.height) & even
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= CVPixelBufferGetWidth(buffer),
              y + height <= CVPixelBufferGetHeight(buffer) else { return nil }
        var out: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &out) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        /// One plane's rows: `rows` of `bytes`, from (`left` bytes, `top` rows).
        func copy(_ plane: Int?, left: Int, top: Int, bytes: Int, rows: Int) -> Bool {
            let from = plane.map { CVPixelBufferGetBaseAddressOfPlane(buffer, $0) } ?? CVPixelBufferGetBaseAddress(buffer)
            let to = plane.map { CVPixelBufferGetBaseAddressOfPlane(out, $0) } ?? CVPixelBufferGetBaseAddress(out)
            guard let from, let to else { return false }
            let fromRow = plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) } ?? CVPixelBufferGetBytesPerRow(buffer)
            let toRow = plane.map { CVPixelBufferGetBytesPerRowOfPlane(out, $0) } ?? CVPixelBufferGetBytesPerRow(out)
            for row in 0 ..< rows { memcpy(to + row * toRow, from + (top + row) * fromRow + left, bytes) }
            return true
        }
        if biplanar {
            // Brightness, a byte a pixel; then colour, a pair of bytes for each 2×2.
            guard copy(0, left: x, top: y, bytes: width, rows: height),
                  copy(1, left: x, top: y / 2, bytes: width, rows: height / 2) else { return nil }
        } else {
            guard copy(nil, left: x * 4, top: y, bytes: width * 4, rows: height) else { return nil }
        }
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
                            mask: MotionMask) -> [Detection]? {
        guard var found = detect(whole) else { return nil }
        let source = closer ?? whole
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        for area in areas(mask) {
            guard let rect = crop(area, width: width, height: height),
                  let part = picture(source, cropped: rect),
                  let near = detect(part) else { continue }
            found += mapped(near, from: rect, width: width, height: height)
        }
        return Duplicates.merged(found)
    }
}
