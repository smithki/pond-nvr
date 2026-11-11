// What a camera check found, as lines for people: the CLI prints them with ✓ ! ✗, the app shows them
// with icons. One wording for both.
import Foundation
import Ingest

public struct CheckLine: Equatable, Sendable {
    public enum Kind: Sendable { case ok, warning, error }

    /// What would put a problem right, for the app to offer.
    public enum Fix: Sendable, Equatable {
        /// The password (or username) is wrong, or there is none.
        case password
        /// The camera could not be reached at its address.
        case address
        /// The camera's privacy mode is on.
        case privacyMode
        /// The camera sends nothing, likely busy with other viewers.
        case busy
        /// Something in the camera's own settings (codec, keyframe interval).
        case cameraSettings
        /// macOS does not let the app reach devices on the local network.
        case localNetwork
        /// It failed in a way pond cannot explain; nothing is suggested beyond trying again.
        case unexplained
    }

    public var kind: Kind
    public var text: String
    public var fix: Fix?

    public init(_ kind: Kind, _ text: String, fix: Fix? = nil) {
        self.kind = kind
        self.text = text
        self.fix = fix
    }

    /// The line as the CLI prints it.
    public var console: String {
        switch kind {
        case .ok: "✓ " + text
        case .warning: "! " + text
        case .error: "✗ " + text
        }
    }
}

public enum CameraCheck {
    /// A camera connection error in plain words, and the fix it points to: only what the error itself says,
    /// nothing guessed (an error with no clear cause says so, with no fix).
    public static func plain(_ error: RTSPError, host: String) -> (text: String, fix: CheckLine.Fix) {
        switch error {
        case .transport(.unreachable):
            ("Nothing answered at \(host).", .address)
        case .transport(.refused):
            ("Something answered at \(host), but turned the video connection down: is RTSP on in the camera\u{2019}s settings, on its usual port?", .address)
        case .transport(.closed):
            ("The camera at \(host) closed the connection.", .unexplained)
        case .transport(.failed):
            ("The connection to \(host) failed.", .unexplained)
        case .unauthorized:
            ("The camera refused the username or the password.", .password)
        case .notFound:
            ("The camera at \(host) has no video at the address Pond uses for it.", .address)
        case .timeout:
            ("The camera at \(host) took the connection but didn\u{2019}t answer.", .unexplained)
        case .status:
            ("The camera at \(host) turned the request for video down.", .unexplained)
        case .malformed:
            ("The camera at \(host) answered in a way Pond couldn\u{2019}t read.", .unexplained)
        }
    }

    /// Lines for a check of the camera at `host` with this username. `passed` is false when the camera
    /// could not be reached or refused the login; warnings alone still pass.
    /// - Parameter cameraApp: where the camera's own settings are changed, as advice names it: its brand's
    ///   app when its provider is known, else in general terms.
    public static func lines(_ result: Result<ProbeReport, RTSPError>, host: String, username: String,
                             watchedSeconds: Double,
                             cameraApp: String = "the camera\u{2019}s own app") -> (lines: [CheckLine], passed: Bool) {
        let report: ProbeReport
        switch result {
        case .failure(.unauthorized):
            return ([CheckLine(.error, "The camera refused the username \(username) or the password.", fix: .password)], false)
        case let .failure(error):
            let (text, fix) = plain(error, host: host)
            return ([CheckLine(.error, text, fix: fix)], false)
        case let .success(r):
            report = r
        }
        var out = [CheckLine(.ok, "main stream: " + describe(report.main))]
        if let sub = report.sub { out.append(CheckLine(.ok, "sub-stream: " + describe(sub))) }
        if report.main.videoCodec == "H.265" {
            out.append(CheckLine(.warning, "The main stream is H.265. HomeKit needs H.264, so pond will have to transcode it; choose H.264 in the camera's settings if it offers it.", fix: .cameraSettings))
        }
        switch report.flow {
        case nil:
            break
        case .privacyMode?:
            out.append(CheckLine(.warning, "No video: the camera is in privacy mode. Turn privacy mode off in \(cameraApp).", fix: .privacyMode))
        case .noVideo?:
            out.append(CheckLine(.warning, "No video arrived in \(number(watchedSeconds)) s. The camera may be busy with too many viewers.", fix: .busy))
        case let .flowing(stats)?:
            var parts: [String] = []
            if let fps = stats.fps { parts.append(String(format: "%.1f fps", fps)) }
            if let k = stats.keyframeInterval {
                parts.append(String(format: "a keyframe every %.1f s", k))
            } else {
                parts.append("fewer than 2 keyframes seen")
            }
            parts.append(String(format: "%.1f Mbit/s", stats.megabitsPerSecond))
            out.append(CheckLine(.ok, "video arriving: " + parts.joined(separator: ", ")))
            if let k = stats.keyframeInterval, k > 4.5 {
                out.append(CheckLine(.warning, String(format: "Keyframes are %.1f s apart. HomeKit Secure Video wants one every 4 s or less: lower the Interframe Space in the camera's settings.", k), fix: .cameraSettings))
            }
        }
        return (out, true)
    }

    public static func describe(_ s: StreamInfo) -> String {
        var parts: [String] = []
        var video = s.videoCodec ?? "no video"
        if let sps = s.sps {
            video += " \(sps.profileName) \(sps.levelName), \(sps.width)×\(sps.height)"
        } else if let h265 = s.h265 {
            video += " \(h265)"
        } else if s.videoCodec == "H.264" || s.videoCodec == "H.265" {
            video += " (resolution not announced)"
        }
        parts.append(video)
        if let a = s.audio {
            let rate = a.sampleRate % 1000 == 0 ? "\(a.sampleRate / 1000) kHz" : String(format: "%.1f kHz", Double(a.sampleRate) / 1000)
            parts.append("\(a.profileName) \(rate) \(a.channels == 1 ? "mono" : a.channels == 2 ? "stereo" : "\(a.channels) channels")")
        } else if let codec = s.audioCodec {
            parts.append(codec)
        }
        return parts.joined(separator: ", ")
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
    }
}
