// SPDX-License-Identifier: MIT
// The signaling service's messages, one JSON object a WebSocket text frame (the service: signaling/, SignalServer):
//   → {"op":"hello","mailbox":HEX,"secret":BASE64}            ← {"op":"ready"} | {"op":"error","why":…} (closed)
//   → {"op":"send","to":HEX,"sealed":BASE64}                  ← {"op":"sent"} | {"op":"undelivered","to":HEX}
//                                                             ← {"op":"envelope","to":HEX,"sealed":BASE64} (to the recipient)
// Plain Foundation, so the service builds on Linux.
import Foundation

public struct SignalMessage: Codable, Equatable, Sendable {
    public var op: String
    public var mailbox: String?
    public var secret: Data?
    public var to: String?
    public var sealed: Data?
    public var why: String?

    public init(op: String, mailbox: String? = nil, secret: Data? = nil, to: String? = nil, sealed: Data? = nil, why: String? = nil) {
        self.op = op
        self.mailbox = mailbox
        self.secret = secret
        self.to = to
        self.sealed = sealed
        self.why = why
    }
}
