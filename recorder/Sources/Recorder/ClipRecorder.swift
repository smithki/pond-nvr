// Records a fixed length of one camera's stream to a single MP4 file: the check that ingest and the MP4
// writer work end to end (`pond camera record`). Continuous recording reuses StreamRecorder with rotating
// files.
import Foundation
import Ingest
import Media

public struct ClipReport: Sendable, Equatable {
    public var seconds: Double
    public var bytes: Int
    public var videoFrames: Int
    public var audioFrames: Int
    public var width: Int
    public var height: Int
    public var lostPackets: Int
    public var startWallTime: Double?

    public init(seconds: Double, bytes: Int, videoFrames: Int, audioFrames: Int, width: Int, height: Int,
                lostPackets: Int, startWallTime: Double?) {
        self.seconds = seconds
        self.bytes = bytes
        self.videoFrames = videoFrames
        self.audioFrames = audioFrames
        self.width = width
        self.height = height
        self.lostPackets = lostPackets
        self.startWallTime = startWallTime
    }
}

public enum ClipError: Error, CustomStringConvertible {
    case camera(RTSPError)
    case file(String)
    case noVideo(Double)

    public var description: String {
        switch self {
        case let .camera(e): e.description
        case let .file(reason): reason
        case let .noVideo(s): String(format: "no keyframe arrived in %.0f s (privacy mode?)", s)
        }
    }
}

public protocol ClipRecording {
    func record(url: String, username: String, password: String, seconds: Double, to path: String) throws(ClipError) -> ClipReport
}

public struct RTSPClipRecorder: ClipRecording {
    public init() {}

    public func record(url: String, username: String, password: String, seconds: Double,
                       to path: String) throws(ClipError) -> ClipReport {
        let session: CameraSession
        do {
            session = try CameraSession(url: url, username: username, password: password)
        } catch {
            throw .camera(error)
        }
        defer { session.close() }
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path) else {
            throw .file("\(path) could not be created")
        }
        defer { try? file.close() }

        let recorder = StreamRecorder(video: session.video, audio: session.audio)
        var bytes = 0
        var startWall: Double?
        func write(_ outputs: [StreamRecorder.Output]) throws(ClipError) {
            for output in outputs {
                let data: [UInt8]
                switch output {
                case let .start(initSegment, wall):
                    data = initSegment
                    startWall = wall
                case let .fragment(f):
                    data = f
                case .end:
                    continue
                }
                do {
                    try file.write(contentsOf: Data(data))
                } catch {
                    throw .file("writing \(path) failed: \(error.localizedDescription)")
                }
                bytes += data.count
            }
        }

        let begun = Date()
        // Wait up to 10 s for the first keyframe, then record `seconds` from it.
        while true {
            let elapsed = Date().timeIntervalSince(begun)
            if startWall == nil, elapsed > 10 { throw .noVideo(10) }
            if startWall != nil, recorder.writtenSeconds >= seconds { break }
            let packet: InterleavedPacket?
            do {
                packet = try session.next(timeout: 1)
            } catch {
                throw .camera(error)
            }
            guard let packet else { continue }
            try write(recorder.handle(packet, now: Date().timeIntervalSince1970))
            if startWall != nil, Date().timeIntervalSince(begun) > seconds + 15 { break }   // stalled
        }
        try write(recorder.finish())
        let track = recorder.videoTrack
        return ClipReport(seconds: recorder.writtenSeconds, bytes: bytes, videoFrames: recorder.videoFrames,
                          audioFrames: recorder.audioFrames, width: track?.width ?? 0, height: track?.height ?? 0,
                          lostPackets: recorder.lostPackets, startWallTime: startWall)
    }
}
