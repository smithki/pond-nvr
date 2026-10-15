// Checks a camera the way `pond camera add` and `pond camera test` need: can we log in, what do the streams
// carry, and (optionally) is video actually arriving.
import Foundation

public struct StreamInfo: Sendable, Equatable, Codable {
    public var videoCodec: String?
    public var sps: H264SPS?
    public var audio: AACConfig?
    public var audioCodec: String?

    public init(_ sdp: SDP) {
        if let v = sdp.video {
            videoCodec = switch v.encoding.uppercased() {
            case "H264": "H.264"
            case "H265": "H.265"
            default: v.encoding
            }
            sps = v.format["sprop-parameter-sets"].flatMap(H264SPS.init(spropParameterSets:))
        }
        if let a = sdp.audio {
            audioCodec = a.encoding
            if a.encoding.uppercased() == "MPEG4-GENERIC" { audio = a.format["config"].flatMap(AACConfig.init(hex:)) }
        }
    }

    public init(videoCodec: String?, sps: H264SPS?, audio: AACConfig?, audioCodec: String?) {
        self.videoCodec = videoCodec
        self.sps = sps
        self.audio = audio
        self.audioCodec = audioCodec
    }
}

public struct ProbeReport: Sendable, Equatable, Codable {
    public var main: StreamInfo
    public var sub: StreamInfo?
    /// Present when the probe watched the main stream's video.
    public var flow: FlowResult?

    public init(main: StreamInfo, sub: StreamInfo?, flow: FlowResult?) {
        self.main = main
        self.sub = sub
        self.flow = flow
    }
}

public protocol CameraProber: Sendable {
    /// Logs in and describes both streams; then, if `watchSeconds` > 0, plays the main stream's video for that
    /// long. Throws if the camera cannot be reached or refuses the login.
    func probe(main: String, sub: String?, username: String, password: String,
               watchSeconds: Double) throws(RTSPError) -> ProbeReport
}

public struct RTSPProber: CameraProber, Sendable {
    public var connectTimeout: Double

    public init(connectTimeout: Double = 5) {
        self.connectTimeout = connectTimeout
    }

    public func probe(main: String, sub: String?, username: String, password: String,
                      watchSeconds: Double) throws(RTSPError) -> ProbeReport {
        let mainClient = try connect(main, username: username, password: password)
        let (mainSDP, base) = try mainClient.describe(main)
        var report = ProbeReport(main: StreamInfo(mainSDP), sub: nil, flow: nil)
        if let sub {
            let subClient = try connect(sub, username: username, password: password)
            report.sub = StreamInfo(try subClient.describe(sub).sdp)
            subClient.transport.close()
        }
        if watchSeconds > 0, let video = mainSDP.video {
            try mainClient.setup(SDP.trackURL(base: base, control: video.control), channel: 0)
            let start = Date()
            try mainClient.play(base)
            var analyzer = FlowAnalyzer(rtpChannel: 0, clockRate: video.clockRate > 0 ? video.clockRate : 90000)
            while true {
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < watchSeconds else { break }
                guard let packet = try mainClient.nextPacket(timeout: watchSeconds - elapsed) else { break }
                analyzer.add(packet, at: Date().timeIntervalSince(start))
            }
            report.flow = analyzer.result(seconds: Date().timeIntervalSince(start))
            if report.main.sps == nil, case let .flowing(stats)? = report.flow { report.main.sps = stats.sps }
            mainClient.teardown(base)
        }
        mainClient.transport.close()
        return report
    }

    private func connect(_ url: String, username: String, password: String) throws(RTSPError) -> RTSPClient {
        guard let parts = URLComponents(string: url), let host = parts.host else { throw .malformed("bad address \(url)") }
        do {
            let transport = try SocketTransport(host: host, port: parts.port ?? 554, timeout: connectTimeout)
            return RTSPClient(transport: transport, username: username, password: password)
        } catch {
            throw .transport(error)
        }
    }
}

/// A camera check as JSON, for the app (which runs `pond camera test ID --json`, so only pond reads the
/// Keychain): the report, or what went wrong.
public struct ProbeOutcome: Codable, Sendable, Equatable {
    public var report: ProbeReport?
    public var error: RTSPError?

    public init(_ result: Result<ProbeReport, RTSPError>) {
        switch result {
        case let .success(r): report = r
        case let .failure(e): error = e
        }
    }

    public var result: Result<ProbeReport, RTSPError>? {
        if let report { return .success(report) }
        return error.map { .failure($0) }
    }
}
