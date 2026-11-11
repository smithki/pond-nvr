// RTSP authentication: Digest (RFC 2617, what Reolink asks for) and Basic.
import Foundation

public enum AuthChallenge: Equatable, Sendable {
    case digest(realm: String, nonce: String, qop: String?, opaque: String?)
    case basic(realm: String)

    /// Reads a WWW-Authenticate header. Digest is preferred when a server offers both.
    public static func parse(_ headers: [String]) -> AuthChallenge? {
        var basic: AuthChallenge?
        for header in headers {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("digest ") {
                let params = parseParams(String(trimmed.dropFirst(7)))
                guard let realm = params["realm"], let nonce = params["nonce"] else { continue }
                let qop = params["qop"].flatMap { list in
                    list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0 == "auth" }
                }
                return .digest(realm: realm, nonce: nonce, qop: qop, opaque: params["opaque"])
            }
            if lower.hasPrefix("basic") {
                basic = .basic(realm: parseParams(String(trimmed.dropFirst(5)))["realm"] ?? "")
            }
        }
        return basic
    }

    /// key="value", key=value, ... with commas inside quotes kept.
    static func parseParams(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " || s[i] == "," { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i ..< eq].trimmingCharacters(in: .whitespaces).lowercased()
            var j = s.index(after: eq)
            var value = ""
            if j < s.endIndex, s[j] == "\"" {
                j = s.index(after: j)
                while j < s.endIndex, s[j] != "\"" {
                    if s[j] == "\\", s.index(after: j) < s.endIndex { j = s.index(after: j) }
                    value.append(s[j])
                    j = s.index(after: j)
                }
                if j < s.endIndex { j = s.index(after: j) }
            } else {
                while j < s.endIndex, s[j] != "," { value.append(s[j]); j = s.index(after: j) }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            out[key] = value
            i = j
        }
        return out
    }

    /// The Authorization header for one request. `nc` counts requests made with this nonce (qop=auth only).
    public func authorization(method: String, uri: String, username: String, password: String,
                              nc: Int = 1, cnonce: String = Self.makeCnonce()) -> String {
        switch self {
        case .basic:
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case let .digest(realm, nonce, qop, opaque):
            let ha1 = MD5.hex("\(username):\(realm):\(password)")
            let ha2 = MD5.hex("\(method):\(uri)")
            var header = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
            if let qop {
                let ncText = String(format: "%08x", nc)
                let response = MD5.hex("\(ha1):\(nonce):\(ncText):\(cnonce):\(qop):\(ha2)")
                header += ", qop=\(qop), nc=\(ncText), cnonce=\"\(cnonce)\", response=\"\(response)\""
            } else {
                header += ", response=\"\(MD5.hex("\(ha1):\(nonce):\(ha2)"))\""
            }
            if let opaque { header += ", opaque=\"\(opaque)\"" }
            return header
        }
    }

    public static func makeCnonce() -> String {
        (0 ..< 8).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }
}
