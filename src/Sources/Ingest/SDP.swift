// The parts of a session description (SDP, RFC 8866) needed to set up and recognise the streams.
import Foundation

public struct SDP: Sendable, Equatable {
    public struct Media: Sendable, Equatable, Codable {
        /// "video" or "audio".
        public var kind: String
        public var payloadType: Int
        /// From a=rtpmap, e.g. "H264", "H265", "MPEG4-GENERIC".
        public var encoding: String
        public var clockRate: Int
        /// From a=fmtp, keys in lowercase.
        public var format: [String: String]
        /// From a=control: a track URL, absolute or relative to the session.
        public var control: String?
        /// From a=sendonly, a=recvonly, a=sendrecv, as the client sees it: "sendonly" is a track the
        /// client sends on (ONVIF's backchannel, to the camera's speaker).
        public var direction: String?
    }

    public var media: [Media]

    public var video: Media? { media.first { $0.kind == "video" } }
    public var audio: Media? { media.first { $0.kind == "audio" && $0.direction != "sendonly" } }
    /// The track for sound to the camera (ONVIF's backchannel), when asked for and offered.
    public var backchannel: Media? { media.first { $0.kind == "audio" && $0.direction == "sendonly" } }

    public init(media: [Media]) { self.media = media }

    public init(_ text: String) {
        var media: [Media] = []
        // Lines end in CRLF (or LF): split where any line ends. (Not on "\n": in Swift, CRLF is one character,
        // which Linux's Foundation doesn't split inside, and every SDP came out as a single line there.)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 4 else { continue }
                media.append(Media(kind: String(parts[0]), payloadType: Int(parts[3]) ?? -1, encoding: "",
                                   clockRate: 0, format: [:], control: nil))
                continue
            }
            guard !media.isEmpty else { continue }
            let n = media.count - 1
            if line.hasPrefix("a=rtpmap:") {
                // a=rtpmap:96 H264/90000
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let codec = parts[1].split(separator: "/")
                media[n].encoding = codec.first.map(String.init) ?? ""
                media[n].clockRate = codec.count > 1 ? Int(codec[1]) ?? 0 : 0
            } else if line.hasPrefix("a=fmtp:") {
                // a=fmtp:96 packetization-mode=1;profile-level-id=640033;sprop-parameter-sets=...
                let parts = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                for pair in parts[1].split(separator: ";") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    media[n].format[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        kv[1].trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("a=control:") {
                media[n].control = String(line.dropFirst(10))
            } else if ["a=sendonly", "a=recvonly", "a=sendrecv", "a=inactive"].contains(line) {
                media[n].direction = String(line.dropFirst(2))
            }
        }
        self.media = media
    }

    /// The URL to SETUP for a track: its control attribute, resolved against the session URL.
    public static func trackURL(base: String, control: String?) -> String {
        guard let control, control != "*" else { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}
