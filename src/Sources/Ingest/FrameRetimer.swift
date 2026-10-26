// Even frame times, for a camera whose stamps bunch. Some cameras stamp a frame when they send it, not when they
// took it: a Wi-Fi doorbell's large keyframe takes a quarter of a second to send, the frames behind it wait and then
// go out together, and played by their stamps, the video freezes and then rushes every couple of seconds. Its frame
// rate itself is steady, so the frames are placed evenly instead: one measured spacing after the last (the camera's
// own spacing, averaged over its last 64 frames, where bunching evens out), drawn gently towards the camera's clock
// so they can't drift from it (each step within a quarter of the spacing either way). A camera with even stamps
// comes out as it went in. A jump (half a second or more from where the next frame belongs: a reconnect, a pause)
// starts again from the camera's time; a camera whose frames come out of order (B-frames) is left as it is.
import Foundation

public struct FrameRetimer: Sendable {
    /// The clock's rate (90 kHz for video).
    let rate: Int64
    private var recent: [Int64] = []
    private var lastCamera: Int64?
    private var lastPlaced: Int64?
    /// How far, on average lately, the camera's times are from where frames were placed.
    private var drift = 0.0
    /// Frames out of order (B-frames): placed as they're stamped.
    private var reordered = false

    /// Frames averaged over for the spacing; and how many before it's trusted (a keyframe group's worth: a few
    /// frames of a bunching camera's are all bunch, and spacing measured from them is wrong).
    static let window = 64, settling = 40

    public init(rate: Int = 90000) { self.rate = Int64(rate) }

    /// Where a frame stamped `camera` (unwrapped) is placed.
    public mutating func place(_ camera: Int64) -> Int64 {
        defer { lastCamera = camera }
        if let previous = lastCamera, camera < previous { reordered = true }
        guard !reordered, let last = lastPlaced, let previous = lastCamera else { return anchor(camera) }
        // A jump (a reconnect, a pause, a clock that moved): from the camera's time again.
        if abs(camera - previous) > rate / 2 { return anchor(camera) }
        recent.append(camera)
        if recent.count > Self.window { recent.removeFirst() }
        // Until the spacing's known, as stamped (never before the last).
        guard recent.count >= Self.settling else { return keep(max(last + 1, camera)) }
        let spacing = Double(recent.last! - recent.first!) / Double(recent.count - 1)
        let next = Double(last) + spacing
        drift = drift * 0.98 + (Double(camera) - next) * 0.02
        let pull = min(spacing / 4, max(-spacing / 4, drift * 0.1))
        // Too far from the camera's clock (stamps that have changed): from its time again.
        if abs(Double(camera) - next) > Double(rate) / 2 { return anchor(camera) }
        return keep(max(last + 1, Int64((next + pull).rounded())))
    }

    private mutating func anchor(_ camera: Int64) -> Int64 {
        recent = [camera]
        drift = 0
        lastPlaced = camera
        return camera
    }

    private mutating func keep(_ time: Int64) -> Int64 {
        lastPlaced = time
        return time
    }
}
