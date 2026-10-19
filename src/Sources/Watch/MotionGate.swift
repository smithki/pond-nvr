// Whether anything moves in a camera's picture, and where: its brightness on a coarse grid (the picture's luma
// averaged into cells), against a background that follows slow changes (daylight, clouds, a lamp) but not quick
// ones. Cells that differ from the background by more than a little are moving. The model only runs while
// something moves, and only what overlaps the moving cells counts (a car parked in view is found in every picture,
// but never starts an event; someone walking past it does).
import Foundation

public struct MotionGate: Sendable {
    public let columns: Int
    public let rows: Int
    /// A cell moves when its brightness is this far (0…255) from the background.
    public var threshold: Float
    /// How fast the background follows the picture (each frame, this share of the difference).
    public var learning: Float
    /// At least this many cells moving, for motion (a speck of noise isn't).
    public var minimumCells: Int
    /// Cells where motion doesn't count (in an ignored zone).
    public var ignored: Set<Int> = []
    private var background: [Float]?

    public init(columns: Int = 32, rows: Int = 24, threshold: Float = 18, learning: Float = 0.05, minimumCells: Int = 3) {
        self.columns = columns
        self.rows = rows
        self.threshold = threshold
        self.learning = learning
        self.minimumCells = minimumCells
    }

    /// Which cells move in this picture (its luma averaged on the grid: `cells`, row by row); none on the first.
    public mutating func moving(_ cells: [Float]) -> MotionMask {
        guard cells.count == columns * rows else { return MotionMask(columns: columns, rows: rows, cells: []) }
        guard var background else {
            self.background = cells
            return MotionMask(columns: columns, rows: rows, cells: [])
        }
        var moving: [Int] = []
        for i in cells.indices {
            let difference = cells[i] - background[i]
            if abs(difference) > threshold, !ignored.contains(i) { moving.append(i) }
            background[i] += difference * learning
        }
        self.background = background
        return MotionMask(columns: columns, rows: rows, cells: moving.count >= minimumCells ? Set(moving) : [])
    }

    /// The picture's brightness averaged on the grid: `pixels` is 32BGRA, `width`×`height`, `stride` bytes a row.
    public static func cells(bgra pixels: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int, columns: Int, rows: Int) -> [Float] {
        var sums = [Float](repeating: 0, count: columns * rows)
        var counts = [Float](repeating: 0, count: columns * rows)
        // Every fourth pixel each way is plenty for a coarse grid.
        for y in Swift.stride(from: 0, to: height, by: 4) {
            let row = min(rows - 1, y * rows / height)
            let line = pixels + y * stride
            for x in Swift.stride(from: 0, to: width, by: 4) {
                let i = row * columns + min(columns - 1, x * columns / width)
                let p = line + x * 4
                sums[i] += Float(Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) / 256
                counts[i] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }
}

/// The cells moving in a picture (indices into the grid, row by row).
public struct MotionMask: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let cells: Set<Int>

    public var isMoving: Bool { !cells.isEmpty }

    /// Whether a box (fractions of the picture) covers any moving cell.
    public func overlaps(_ box: (x: Double, y: Double, width: Double, height: Double)) -> Bool {
        guard isMoving else { return false }
        let left = max(0, Int(box.x * Double(columns))), right = min(columns - 1, Int((box.x + box.width) * Double(columns)))
        let top = max(0, Int(box.y * Double(rows))), bottom = min(rows - 1, Int((box.y + box.height) * Double(rows)))
        guard left <= right, top <= bottom else { return false }
        for row in top ... bottom {
            for column in left ... right where cells.contains(row * columns + column) { return true }
        }
        return false
    }
}
