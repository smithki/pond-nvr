// How long after its place in the recording each camera's pictures reach the Mac, as the recorder sees it: the
// recorder places frames by its own clock (the camera's, by the main stream's sender reports, from the first frame
// of a session); detection reads the sub-stream, whose own reports can disagree with the main stream's by a second
// or more (measured: 1.6 s on one camera). Detection puts what it finds on the recording's clock with this: when
// its picture arrived, less this lag (two streams from one camera cross the network alike).
import Foundation

public final class StreamLatency: @unchecked Sendable {
    public static let shared = StreamLatency()

    private let lock = NSLock()
    private var lags: [String: Double] = [:]

    public init() {}

    /// One frame of `camera`'s recording: placed at `placed`, arrived at `arrived` (seconds since 1970). Smoothed.
    public func noteRecorded(_ camera: String, placed: Double, arrived: Double) {
        let sample = arrived - placed
        lock.withLock { lags[camera] = lags[camera].map { $0 * 0.95 + sample * 0.05 } ?? sample }
    }

    /// How long after its place in the recording a picture of `camera` arrives; nil before it's recorded.
    public func recordedLag(_ camera: String) -> Double? { lock.withLock { lags[camera] } }
}
