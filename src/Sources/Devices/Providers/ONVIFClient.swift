// An ONVIF camera, talked to: where its device service is (found without logging in, with the camera's
// clock, since the login digest carries the time and a camera refuses one too far from its own), which
// services it has, its media profiles and their stream addresses.
import Foundation
import Ingest

public final class ONVIFClient: @unchecked Sendable {
    public let host: String
    let username: String
    let password: String
    /// The device service, e.g. http://192.168.1.30:8000/onvif/device_service.
    public let deviceService: URL
    /// The camera's clock minus this Mac's, in seconds.
    public let clockOffset: TimeInterval
    /// Told each request and how it went, for `pond camera onvif --trace`.
    public var trace: (@Sendable (String) -> Void)?

    /// Ports ONVIF's device service is usually on: 80, then those some makes use instead (Reolink 8000,
    /// TP-Link 2020, others 8080 and 8899).
    public static let ports = [80, 8000, 8080, 2020, 8899]

    init(host: String, username: String, password: String, deviceService: URL, clockOffset: TimeInterval) {
        self.host = host
        self.username = username
        self.password = password
        self.deviceService = deviceService
        self.clockOffset = clockOffset
    }

    /// The camera at `host`, if its device service answers on one of the usual ports (or `port`).
    public static func connect(host: String, port: Int? = nil, username: String, password: String) async -> ONVIFClient? {
        // Once more after a moment if nothing answered: a process's first connections on the local network
        // fail while macOS decides whether to allow them.
        for attempt in 0 ..< 2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let client = await find(host: host, port: port, username: username, password: password) { return client }
        }
        return nil
    }

    /// Whether ONVIF's device service answers at `host` on `port` (its time, which needs no login).
    public static func answers(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/onvif/device_service") else { return false }
        let body = "<GetSystemDateAndTime xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>"
        return await post(url, ONVIF.plainEnvelope(body), timeout: 3)?.contains("SystemDateAndTime") == true
    }

    private static func find(host: String, port: Int?, username: String, password: String) async -> ONVIFClient? {
        for port in port.map({ [$0] }) ?? ports {
            guard let url = URL(string: "http://\(host):\(port)/onvif/device_service") else { continue }
            let body = "<GetSystemDateAndTime xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>"
            let asked = Date()
            // Short: most of these ports have nothing on them.
            guard let reply = await post(url, ONVIF.plainEnvelope(body), timeout: 3), reply.contains("SystemDateAndTime")
            else { continue }
            let offset = ONVIF.cameraTime(in: reply).map { $0.timeIntervalSince(asked) } ?? 0
            return ONVIFClient(host: host, username: username, password: password, deviceService: url,
                               clockOffset: abs(offset) < 5 ? 0 : offset)
        }
        return nil
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// The reply to `body`, sent to `service` with the login; a SOAP fault or no answer throws.
    /// `action` and the service as WS-Addressing headers, which a subscription's requests need; `timeout` for
    /// one the camera holds open (PullMessages).
    func call(_ service: URL, _ body: String, action: String? = nil, timeout: TimeInterval = 10) async throws(Failure) -> XMLDocument {
        let addressing = action.map {
            "<wsa:Action xmlns:wsa=\"http://www.w3.org/2005/08/addressing\">\($0)</wsa:Action>"
                + "<wsa:To xmlns:wsa=\"http://www.w3.org/2005/08/addressing\">\(ONVIF.escape(service.absoluteString))</wsa:To>"
        } ?? ""
        let envelope = ONVIF.envelope(body, username: username, password: password, created: Date().addingTimeInterval(clockOffset),
                                      header: addressing)
        let action = body.split(separator: " ").first.map { String($0.dropFirst()) } ?? "?"
        let started = Date()
        let (text, outcome) = await Self.exchange(service, envelope, timeout: timeout)
        trace?("\(action) → \(service.absoluteString): \(outcome) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        guard let text else { throw Failure(description: "no answer from \(service.absoluteString) (\(outcome))") }
        guard let document = try? XMLDocument(xmlString: text) else { throw Failure(description: "an answer that isn't XML") }
        if let fault = document.first("Fault") {
            let reason = fault.first("Text")?.stringValue ?? fault.first("Subcode")?.stringValue ?? "a fault"
            throw Failure(description: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return document
    }

    /// The services the camera has, by namespace (e.g. "http://www.onvif.org/ver10/media/wsdl"), at addresses
    /// on the host it was reached at (cameras often report another address for themselves).
    public func services() async throws(Failure) -> [String: URL] {
        var out: [String: URL] = [:]
        if let document = try? await call(deviceService, "<GetServices xmlns=\"http://www.onvif.org/ver10/device/wsdl\"><IncludeCapability>false</IncludeCapability></GetServices>") {
            for service in document.all("Service") {
                if let namespace = service.first("Namespace")?.trimmed, let address = service.first("XAddr")?.trimmed {
                    out[namespace] = reachable(address)
                }
            }
        }
        if out.isEmpty {
            // Older cameras: GetCapabilities, which names media and events by section.
            let document = try await call(deviceService, "<GetCapabilities xmlns=\"http://www.onvif.org/ver10/device/wsdl\"><Category>All</Category></GetCapabilities>")
            for (section, namespace) in [("Media", ONVIF.media), ("Events", ONVIF.events)] {
                if let address = document.first(section)?.first("XAddr")?.trimmed { out[namespace] = reachable(address) }
            }
        }
        return out
    }

    /// The address as reported, on the host this camera was reached at.
    func reachable(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address) else { return nil }
        parts.host = host
        return parts.url
    }

    /// A media profile: a stream the camera offers, with its encoding.
    public struct Profile: Equatable, Sendable {
        public var token: String
        public var name: String
        public var encoding: String
        public var width: Int
        public var height: Int
        public var fps: Int?
    }

    public func profiles(media: URL) async throws(Failure) -> [Profile] {
        let document = try await call(media, "<GetProfiles xmlns=\"http://www.onvif.org/ver10/media/wsdl\"/>")
        return Self.profiles(in: document)
    }

    static func profiles(in document: XMLDocument) -> [Profile] {
        document.all("Profiles").compactMap { profile in
            guard let token = profile.attribute("token"), let video = profile.first("VideoEncoderConfiguration") else { return nil }
            let resolution = video.first("Resolution")
            return Profile(token: token, name: profile.first("Name")?.trimmed ?? token,
                           encoding: video.first("Encoding")?.trimmed ?? "",
                           width: Int(resolution?.first("Width")?.trimmed ?? "") ?? 0,
                           height: Int(resolution?.first("Height")?.trimmed ?? "") ?? 0,
                           fps: Int(video.first("FrameRateLimit")?.trimmed ?? ""))
        }
    }

    /// The RTSP address of a profile, without a login in it and on the host the camera was reached at: asked
    /// of Media2 if the camera has it (simpler, and some cameras answer it where Media's version hangs),
    /// else of Media.
    public func streamAddress(media: URL, media2: URL? = nil, profile: String) async throws(Failure) -> String {
        let token = ONVIF.escape(profile)
        var document: XMLDocument?
        if let media2 {
            document = try? await call(media2, "<GetStreamUri xmlns=\"http://www.onvif.org/ver20/media/wsdl\"><Protocol>RTSP</Protocol><ProfileToken>\(token)</ProfileToken></GetStreamUri>")
        }
        if document == nil {
            document = try await call(media, """
            <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup>\
            <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>\
            <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>\
            </StreamSetup><ProfileToken>\(token)</ProfileToken></GetStreamUri>
            """)
        }
        guard let document, let uri = document.first("Uri")?.trimmed, let address = Self.clean(uri, host: host) else {
            throw Failure(description: "no stream address for profile \(profile)")
        }
        return address
    }

    /// A stream address as settings keep it: no login in it (cameras sometimes put one there), on the host
    /// the camera was reached at.
    static func clean(_ uri: String, host: String) -> String? {
        guard var parts = URLComponents(string: uri), parts.scheme?.lowercased() == "rtsp" else { return nil }
        parts.user = nil
        parts.password = nil
        parts.host = host
        return parts.string
    }

    /// The main stream (the largest profile Pond reads: H.264 or H.265) and the sub-stream (the smallest other one;
    /// the main again if there is only one). Between two the same size, H.264 (the Home app takes it as it is).
    public static func choose(_ profiles: [Profile]) -> (main: Profile, sub: Profile)? {
        let readable = profiles.filter { VideoCodec(encoding: $0.encoding) != nil && $0.width > 0 }
        func pixels(_ p: Profile) -> Int { p.width * p.height }
        func h264(_ p: Profile) -> Int { VideoCodec(encoding: p.encoding) == .h264 ? 1 : 0 }
        guard let main = readable.max(by: { (pixels($0), h264($0)) < (pixels($1), h264($1)) }) else { return nil }
        let others = readable.filter { $0.token != main.token }
        let sub = others.min(by: { (pixels($0), -h264($0)) < (pixels($1), -h264($1)) }) ?? main
        return (main, sub)
    }

    /// The camera's main and sub-stream addresses, as ONVIF describes them.
    public func streams() async throws(Failure) -> (main: String, sub: String) {
        let services = try await services()
        guard let media = services[ONVIF.media] else { throw Failure(description: "the camera has no media service") }
        return try await streams(media: media, media2: services[ONVIF.media2], profiles: try await profiles(media: media))
    }

    /// The same, from profiles already asked for.
    public func streams(media: URL, media2: URL?, profiles: [Profile]) async throws(Failure) -> (main: String, sub: String) {
        guard let (main, sub) = Self.choose(profiles) else {
            throw Failure(description: profiles.isEmpty ? "the camera has no media profiles" : "no profile is H.264 or H.265")
        }
        let mainAddress = try await streamAddress(media: media, media2: media2, profile: main.token)
        let subAddress = sub.token == main.token ? mainAddress
            : try await streamAddress(media: media, media2: media2, profile: sub.token)
        return (mainAddress, subAddress)
    }

    static func post(_ url: URL, _ envelope: String, timeout: TimeInterval = 10) async -> String? {
        await exchange(url, envelope, timeout: timeout).text
    }

    /// The reply's text, and how the exchange went in words (status and size, or the error).
    static func exchange(_ url: URL, _ envelope: String, timeout: TimeInterval = 10) async -> (text: String?, outcome: String) {
        // Some cameras take seconds to answer (a Reolink E1: about 3 s for a stream address).
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // A fault comes with status 400 or 500; its body says what it was.
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (String(data: data, encoding: .utf8), "status \(status), \(data.count) bytes")
        } catch {
            return (nil, (error as NSError).localizedDescription)
        }
    }
}

extension ONVIF {
    /// Media (profiles and stream addresses), as ONVIF names the service.
    public static let mediaNamespace = media
    public static let media2Namespace = media2
    public static let eventsNamespace = events
    static let media = "http://www.onvif.org/ver10/media/wsdl"
    static let media2 = "http://www.onvif.org/ver20/media/wsdl"
    static let events = "http://www.onvif.org/ver10/events/wsdl"

    /// An envelope without a login, for what a camera answers to anyone (its time).
    static func plainEnvelope(_ body: String) -> String {
        "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body>\(body)</s:Body></s:Envelope>"
    }

    /// The camera's UTC time in a GetSystemDateAndTime reply.
    static func cameraTime(in reply: String) -> Date? {
        guard let document = try? XMLDocument(xmlString: reply), let utc = document.first("UTCDateTime") else { return nil }
        func n(_ name: String) -> Int? { Int(utc.first(name)?.trimmed ?? "") }
        guard let year = n("Year"), let month = n("Month"), let day = n("Day") else { return nil }
        var parts = DateComponents(year: year, month: month, day: day, hour: n("Hour"), minute: n("Minute"), second: n("Second"))
        parts.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: parts)
    }
}

extension XMLNode {
    /// The first element under this one with this local name (any namespace).
    func first(_ name: String) -> XMLNode? { all(name).first }

    /// Every element under this one with this local name.
    func all(_ name: String) -> [XMLNode] {
        (try? nodes(forXPath: ".//*[local-name()='\(name)']")) ?? []
    }

    var trimmed: String? { stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func attribute(_ name: String) -> String? { (self as? XMLElement)?.attribute(forName: name)?.stringValue }
}
