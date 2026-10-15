import Foundation
import Ingest
import NVRCLI
import NVRCore

final class RecordingConsole: Console {
    var lines: [String] = []
    var errors: [String] = []
    var interactive = false
    var secret: String?
    var answer: String?
    var input: String?

    func out(_ line: String) { lines.append(line) }
    func err(_ line: String) { errors.append(line) }
    func readSecret(_ prompt: String) -> String? { secret }
    func ask(_ prompt: String) -> String? { answer }
    func readAllInput() -> String? { input }

    var all: String { (lines + errors).joined(separator: "\n") }
}

final class FakeProber: CameraProber, @unchecked Sendable {
    var result: Result<ProbeReport, RTSPError>
    var calls: [(main: String, username: String, password: String, seconds: Double)] = []

    init(_ result: Result<ProbeReport, RTSPError> = .success(FakeProber.good)) { self.result = result }

    func probe(main: String, sub: String?, username: String, password: String,
               watchSeconds: Double) throws(RTSPError) -> ProbeReport {
        calls.append((main, username, password, watchSeconds))
        return try result.get()
    }

    static let reolinkMain = StreamInfo(videoCodec: "H.264", sps: H264SPS(profileIDC: 100, levelIDC: 51, width: 2560, height: 1440),
                                        audio: AACConfig(objectType: 2, sampleRate: 16000, channels: 1), audioCodec: "MPEG4-GENERIC")
    static let reolinkSub = StreamInfo(videoCodec: "H.264", sps: nil, audio: nil, audioCodec: nil)
    static let good = ProbeReport(main: reolinkMain, sub: reolinkSub, flow: .flowing(FlowStats(
        videoPackets: 1000, videoBytes: 2_000_000, seconds: 6, firstVideoAfter: 1, fps: 20, keyframeInterval: 2,
        keyframes: 3, sps: nil)))
}

/// A settings file in a temporary folder, with a prepared recordings folder, and a CLI around it.
final class Harness {
    let dir: String
    let store: ConfigStore
    let console = RecordingConsole()
    let credentials = MemoryCredentialStore()
    let prober: FakeProber

    init(prober: FakeProber = FakeProber(), initialise: Bool = true) throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pond-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        store = ConfigStore(path: dir + "/config.json")
        self.prober = prober
        if initialise {
            #expect(run("init", "--recordings", dir + "/rec", "--database", dir + "/pond.sqlite") == 0)
            console.lines = []
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    var cli: CLI { CLI(store: store, credentials: credentials, prober: prober, console: console) }

    @discardableResult
    func run(_ args: String...) -> Int32 { cli.run(args) }

    var config: Config { get throws { try store.load() } }
}

import Testing
