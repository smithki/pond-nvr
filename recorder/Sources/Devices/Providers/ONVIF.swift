// ONVIF, which most cameras that are not Reolink's (and many that are) answer: SOAP over HTTP, with the
// WS-Security username token: what a camera is, and its streams (ONVIFClient).
import CryptoKit
import Foundation
import PondCore

/// Any ONVIF camera: what it is, and its stream addresses; no doorbell button yet (ONVIF events would bring it).
public struct ONVIFProvider: CameraProvider {
    public let id = "onvif"
    public let name = "ONVIF"
    public init() {}

    public func identify(host: String, username: String, password: String) async -> Config.Device? {
        guard let client = await ONVIFClient.connect(host: host, username: username, password: password) else { return nil }
        return try? await client.deviceInformation()
    }

    public func findStreams(host: String, username: String, password: String) async -> (main: String, sub: String)? {
        guard let client = await ONVIFClient.connect(host: host, username: username, password: password) else { return nil }
        return try? await client.streams()
    }

    /// Motion (and a doorbell's button) from the camera's ONVIF events.
    public func events(host: String, username: String, password: String) -> CameraEvents? {
        ONVIFEvents(host: host, username: username, password: password)
    }
}

extension ONVIFClient {
    /// What the camera says it is (GetDeviceInformation).
    public func deviceInformation() async throws(Failure) -> Config.Device {
        let reply = try await call(deviceService, "<GetDeviceInformation xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>")
        guard let model = reply.first("Model")?.trimmed, !model.isEmpty else { throw Failure(description: "no model in its answer") }
        func text(_ name: String) -> String? { reply.first(name)?.trimmed.flatMap { $0.isEmpty ? nil : $0 } }
        return Config.Device(manufacturer: text("Manufacturer") ?? "", model: model, serial: text("SerialNumber"),
                             firmware: text("FirmwareVersion"), isDoorbell: model.localizedCaseInsensitiveContains("doorbell"),
                             provider: "onvif")
    }
}

/// ONVIF over SOAP, with the WS-Security username token every ONVIF camera takes.
public enum ONVIF {
    static func envelope(_ body: String, username: String, password: String, nonce: [UInt8] = .random(16),
                         created: Date = Date(), header: String = "") -> String {
        let createdText = ISO8601DateFormatter().string(from: created)
        let digest = Data(Insecure.SHA1.hash(data: Data(nonce) + Data(createdText.utf8) + Data(password.utf8)))
        return """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header>\
        <Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" s:mustUnderstand="1">\
        <UsernameToken><Username>\(escape(username))</Username>\
        <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest.base64EncodedString())</Password>\
        <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(Data(nonce).base64EncodedString())</Nonce>\
        <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(createdText)</Created>\
        </UsernameToken></Security>\(header)</s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    /// The text of the first element with this local name (any namespace prefix).
    static func value(of name: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_]+:)?\(name)>([^<]*)</") else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), let r = Range(match.range(at: 1), in: xml) else { return nil }
        let text = String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension Array where Element == UInt8 {
    static func random(_ count: Int) -> [UInt8] { (0 ..< count).map { _ in .random(in: 0 ... 255) } }
}
