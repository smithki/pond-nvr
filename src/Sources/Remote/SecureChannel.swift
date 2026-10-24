// A session's control channel: messages between two Ponds, encrypted, each delivered once and in order, over the
// session's UDP path (which carries its checks and video too: a packet's first byte says which, as RFC 7983 lays
// out; the channel's is 23, in the range DTLS would use, which Pond doesn't).
//
// A frame: [23][kind][sequence, 8 bytes] then its payload sealed with ChaCha20-Poly1305 under this direction's key
// (the header as associated data; the nonce made of the kind and the sequence, so none is used twice). Data frames
// carry a piece of a message (at most 1,100 bytes, so a packet stays under any path's limit: [last?][bytes]); ack
// frames say what's arrived (all up to a number, and those after it). Unacknowledged frames are sent again after a
// timeout from the measured round trip (not from frames sent again: Karn's rule), at most 64 in flight; frames that
// arrive early wait for those before them; duplicates and replays are acknowledged and dropped; anything that
// doesn't open under the key is dropped unread.
import CryptoKit
import Foundation

public final class SecureChannel: @unchecked Sendable {
    public static let marker: UInt8 = 23
    static let data: UInt8 = 0, ack: UInt8 = 1
    static let headerLength = 10, chunk = 1100, window: UInt64 = 64
    static let minimumTimeout = 0.2, maximumTimeout = 3.0

    let sendKey: SymmetricKey, receiveKey: SymmetricKey
    /// A frame out, onto the path.
    let output: @Sendable ([UInt8]) -> Void
    /// A whole message in (on the channel's queue).
    public var received: (@Sendable (Data) -> Void)?

    private let queue = DispatchQueue(label: "pond.channel")
    private var timer: DispatchSourceTimer?
    private var closed = false

    // Sending.
    private var nextSequence: UInt64 = 1
    private var nextAck: UInt64 = 1
    private var outstanding: [UInt64: Sent] = [:]
    private var queued: [[UInt8]] = []
    struct Sent {
        var frame: [UInt8]
        var sentAt: Date
        var resent = false
        var due: Date
    }
    /// Round-trip estimates (RFC 6298).
    private var smoothed: Double?, variation = 0.0

    // Receiving.
    private var delivered: UInt64 = 0
    private var early: [UInt64: [UInt8]] = [:]
    private var partial = Data()

    public init(keys: SessionKeys, output: @escaping @Sendable ([UInt8]) -> Void) {
        sendKey = keys.controlSend
        receiveKey = keys.controlReceive
        self.output = output
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    public func close() {
        queue.sync {
            closed = true
            timer?.cancel()
            timer = nil
        }
    }

    /// The timeout before a frame's sent again: from the round trip once one's measured.
    var timeout: Double {
        guard let smoothed else { return 1 }
        return min(Self.maximumTimeout, max(Self.minimumTimeout, smoothed + 4 * variation))
    }

    // MARK: Sending

    /// A message to the other side: cut into frames, sent as the window allows.
    public func send(_ message: Data) {
        queue.async { [self] in
            guard !closed else { return }
            let bytes = [UInt8](message)
            var at = 0
            repeat {
                let end = min(bytes.count, at + Self.chunk)
                queued.append([end == bytes.count ? 1 : 0] + bytes[at ..< end])
                at = end
            } while at < bytes.count
            pump()
        }
    }

    /// Queued pieces sent while there's room in the window.
    private func pump() {
        while !queued.isEmpty, outstanding.count < Int(Self.window) {
            let sequence = nextSequence
            nextSequence += 1
            let frame = seal(kind: Self.data, sequence: sequence, queued.removeFirst())
            let now = Date()
            outstanding[sequence] = Sent(frame: frame, sentAt: now, due: now.addingTimeInterval(timeout))
            output(frame)
        }
    }

    private func tick() {
        let now = Date()
        for (sequence, sent) in outstanding where now >= sent.due {
            outstanding[sequence]?.resent = true
            outstanding[sequence]?.due = now.addingTimeInterval(min(Self.maximumTimeout, timeout * 2))
            output(sent.frame)
        }
    }

    // MARK: Receiving

    /// A frame from the path (its first byte the channel's).
    public func handle(_ frame: [UInt8]) {
        queue.async { [self] in
            guard !closed, frame.count > Self.headerLength, frame[0] == Self.marker,
                  let payload = open(frame) else { return }
            let kind = frame[1], sequence = Self.be64(frame, 2)
            if kind == Self.ack {
                acknowledged(payload)
                return
            }
            guard kind == Self.data else { return }
            // Within the window ahead of what's been delivered: kept (once); before it: a duplicate, acknowledged again.
            if sequence > delivered, sequence <= delivered + Self.window, early[sequence] == nil {
                early[sequence] = payload
                while let next = early.removeValue(forKey: delivered + 1) {
                    delivered += 1
                    partial.append(contentsOf: next.dropFirst())
                    if next.first == 1 {
                        let message = partial
                        partial = Data()
                        received?(message)
                    }
                }
            }
            sendAck()
        }
    }

    /// What's arrived: all up to `delivered`, and the early ones after it.
    private func sendAck() {
        var payload = Self.be64(delivered)
        for sequence in early.keys.sorted().prefix(32) { payload += Self.be64(sequence) }
        let sequence = nextAck
        nextAck += 1
        output(seal(kind: Self.ack, sequence: sequence, payload))
    }

    private func acknowledged(_ payload: [UInt8]) {
        guard payload.count >= 8, payload.count % 8 == 0 else { return }
        let upTo = Self.be64(payload, 0)
        var done = Set(outstanding.keys.filter { $0 <= upTo })
        for i in stride(from: 8, to: payload.count, by: 8) { done.insert(Self.be64(payload, i)) }
        let now = Date()
        for sequence in done {
            guard let sent = outstanding.removeValue(forKey: sequence) else { continue }
            // (Only a frame sent once says how long a round trip takes.)
            if !sent.resent { measured(now.timeIntervalSince(sent.sentAt)) }
        }
        pump()
    }

    private func measured(_ trip: Double) {
        if let smoothed {
            variation = 0.75 * variation + 0.25 * abs(smoothed - trip)
            self.smoothed = 0.875 * smoothed + 0.125 * trip
        } else {
            smoothed = trip
            variation = trip / 2
        }
    }

    // MARK: Frames

    private func seal(kind: UInt8, sequence: UInt64, _ payload: [UInt8]) -> [UInt8] {
        let header = [Self.marker, kind] + Self.be64(sequence)
        let box = try! ChaChaPoly.seal(payload, using: sendKey, nonce: Self.nonce(kind, sequence), authenticating: header)
        return header + [UInt8](box.ciphertext) + [UInt8](box.tag)
    }

    private func open(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= Self.headerLength + 16 else { return nil }
        let header = Array(frame[0 ..< Self.headerLength])
        let body = frame[Self.headerLength...]
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(frame[1], Self.be64(frame, 2)),
                                                  ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let opened = try? ChaChaPoly.open(box, using: receiveKey, authenticating: header) else { return nil }
        return [UInt8](opened)
    }

    static func nonce(_ kind: UInt8, _ sequence: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [kind, 0, 0, 0] + be64(sequence))
    }

    static func be64(_ v: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8((v >> (56 - 8 * UInt64($0))) & 0xFF) } }
    static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { (0 ..< 8).reduce(0) { $0 << 8 | UInt64(b[i + $1]) } }
}
