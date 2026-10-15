// ONVIF, which most cameras that are not Reolink's (and many that are) answer: SOAP over HTTP, with the
// WS-Security username token. So far only what a camera is (GetDeviceInformation).
import CryptoKit
import Foundation
import NVRCore

/// Any ONVIF camera: identifies it; no doorbell button yet (ONVIF events would bring it).
public struct ONVIFProvider: CameraProvider {
    public let id = "onvif"
    public init() {}

    public func identify(host: String, username: String, password: String) async -> Config.Device? {
        await ONVIF.deviceInformation(host: host, username: username, password: password)
            .map { var d = $0; d.provider = id; return d }
    }
}

/// ONVIF over SOAP, with the WS-Security username token every ONVIF camera takes.
enum ONVIF {
    /// Where ONVIF's device service usually is: port 80, or 8000 (Reolink and others).
    static let ports = [80, 8000, 8080]

    static func deviceInformation(host: String, username: String, password: String) async -> Config.Device? {
        let body = "<GetDeviceInformation xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>"
        for port in ports {
            guard let reply = await call(host: host, port: port, body: body, username: username, password: password)
            else { continue }
            guard let model = value(of: "Model", in: reply) else { return nil }
            return Config.Device(manufacturer: value(of: "Manufacturer", in: reply) ?? "", model: model,
                                 serial: value(of: "SerialNumber", in: reply), firmware: value(of: "FirmwareVersion", in: reply),
                                 isDoorbell: model.localizedCaseInsensitiveContains("doorbell"))
        }
        return nil
    }

    /// The reply's text, or nil if nothing answered or it was not a success.
    static func call(host: String, port: Int, body: String, username: String, password: String) async -> String? {
        guard let url = URL(string: "http://\(host):\(port)/onvif/device_service") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope(body, username: username, password: password).utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func envelope(_ body: String, username: String, password: String, nonce: [UInt8] = .random(16),
                         created: Date = Date()) -> String {
        let createdText = ISO8601DateFormatter().string(from: created)
        let digest = Data(Insecure.SHA1.hash(data: Data(nonce) + Data(createdText.utf8) + Data(password.utf8)))
        return """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Header>\
        <Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" s:mustUnderstand="1">\
        <UsernameToken><Username>\(escape(username))</Username>\
        <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest.base64EncodedString())</Password>\
        <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(Data(nonce).base64EncodedString())</Nonce>\
        <Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\(createdText)</Created>\
        </UsernameToken></Security></s:Header><s:Body>\(body)</s:Body></s:Envelope>
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
