// A session's control channel: messages between two Ponds, encrypted, each delivered once and in order, over the
// session's UDP path (which carries its checks and video too: a packet's first byte says which, as RFC 7983 lays
// out; the channel's is 23, in the range DTLS would use, which Pond doesn't).
//
// A frame: [23][kind][sequence, 8 bytes] then its payload sealed with ChaCha20-Poly1305 under this direction's key
// (the header as associated data; the nonce made of the kind and the sequence, so none is used twice). Data frames
// carry a piece of a message (at most 1,100 bytes, so a packet stays under any path's limit: [last?][bytes]); ack
// frames say what's arrived (all up to a number, then the ranges after it that have come too). Frames that arrive
// early wait for those before them; duplicates and replays are acknowledged and dropped; anything that doesn't open
// under the key is dropped unread.
//
// How many frames are in flight follows the link, as BBR does for TCP: doubling each round trip from the start
// until the rate frames are acknowledged at stops growing, then twice what the link carries in a round trip (its
// best rate lately, times its shortest round trip). So a clip fills a fast link, a slow one isn't flooded, and a
// frame lost here and there (Wi-Fi, cellular) doesn't slow it down as it would TCP; only heavy loss does. A frame
// is sent again as soon as three after it have arrived, or after a timeout from the measured round trip (not from
// frames sent again: Karn's rule).
import CryptoKit
import Foundation

public final class SecureChannel: @unchecked Sendable {
    public static let marker: UInt8 = 23
    static let data: UInt8 = 0, ack: UInt8 = 1
    static let headerLength = 10, chunk = 1100
    static let minimumTimeout = 0.2, maximumTimeout = 3.0
    /// Frames in flight: at first, at least, at most (4,096: about 4.5 MB, a fast link across a continent); and
    /// how far past what's been delivered frames are kept.
    static let initialWindow = 32.0, minimumWindow = 16.0, maximumWindow = 4096.0
    static let receiveWindow: UInt64 = 4096

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
    /// Round-trip estimates (RFC 6298), and the shortest lately (the link's own, without queues).
    private var smoothed: Double?, variation = 0.0
    private var shortest: (trip: Double, at: Date)?

    /// Frames allowed in flight; still finding the link's rate (doubling each round trip).
    private(set) var window = SecureChannel.initialWindow
    private var startup = true
    /// The link's rate (frames a second), as measured each round trip lately; the best while starting, and how many
    /// round trips since it last grew.
    private var rates: [Double] = []
    private var startupBest = 0.0, startupStalls = 0
    /// This round trip: from the frame sent first in it, when, and what's been acknowledged and lost since; and
    /// whether there was less to send than the window allowed (its rate isn't the link's then).
    private var round = Round(sequence: 1, at: Date())
    struct Round {
        var sequence: UInt64
        var at: Date
        var acked = 0, lost = 0
        var limited = false
        var timedOut = false
    }
    /// The highest frame known to have arrived; how far frames behind it have been checked for loss; the oldest
    /// still in flight; and those sent again, waiting to be heard of.
    private var highestAcked: UInt64 = 0
    private var scanned: UInt64 = 1
    private var oldest: UInt64 = 1
    private var holes = Set<UInt64>()

    // Receiving.
    private var delivered: UInt64 = 0
    private var early: [UInt64: [UInt8]] = [:]
    /// The early ones, as ranges, in order (kept as they come: what each ack says).
    private var ranges: [ClosedRange<UInt64>] = []
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
        let now = Date()
        // (Never further past the oldest still in flight than the other side keeps frames: those would be dropped.)
        while !queued.isEmpty, Double(outstanding.count) < window, nextSequence - oldest < Self.receiveWindow {
            let sequence = nextSequence
            nextSequence += 1
            let frame = seal(kind: Self.data, sequence: sequence, queued.removeFirst())
            outstanding[sequence] = Sent(frame: frame, sentAt: now, due: now.addingTimeInterval(timeout))
            output(frame)
        }
        // Less to send than allowed: this round's rate is what was sent, not what the link could carry.
        if queued.isEmpty, Double(outstanding.count) < window / 2 { round.limited = true }
    }

    private func tick() {
        let now = Date()
        var lost = 0
        for (sequence, sent) in outstanding where now >= sent.due {
            outstanding[sequence]?.resent = true
            outstanding[sequence]?.due = now.addingTimeInterval(min(Self.maximumTimeout, timeout * 2))
            output(sent.frame)
            holes.insert(sequence)
            lost += 1
        }
        // Nothing heard for a whole timeout (a path that's gone, a link swamped): half as many in flight, once a
        // round trip.
        if lost > 0 {
            round.lost += lost
            if !round.timedOut {
                round.timedOut = true
                window = max(Self.minimumWindow, window / 2)
                startup = false
            }
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
            if sequence > delivered, sequence <= delivered + Self.receiveWindow, early[sequence] == nil {
                early[sequence] = payload
                note(sequence)
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
            ranges.removeAll { $0.upperBound <= delivered }
            sendAck()
        }
    }

    /// An early frame added to the ranges (merging those it joins).
    private func note(_ sequence: UInt64) {
        guard let i = ranges.firstIndex(where: { sequence <= $0.upperBound + 1 }) else {
            ranges.append(sequence ... sequence)
            return
        }
        if ranges[i].contains(sequence) { return }
        if sequence + 1 < ranges[i].lowerBound {
            ranges.insert(sequence ... sequence, at: i)
        } else if sequence + 1 == ranges[i].lowerBound {
            ranges[i] = sequence ... ranges[i].upperBound
        } else {
            ranges[i] = ranges[i].lowerBound ... sequence
            if i + 1 < ranges.count, ranges[i + 1].lowerBound == sequence + 1 {
                ranges[i] = ranges[i].lowerBound ... ranges[i + 1].upperBound
                ranges.remove(at: i + 1)
            }
        }
    }

    /// What's arrived: all up to `delivered`, then the ranges of early ones after it (the first 64).
    private func sendAck() {
        var payload = Self.be64(delivered)
        for range in ranges.prefix(64) { payload += Self.be64(range.lowerBound) + Self.be64(range.upperBound) }
        let sequence = nextAck
        nextAck += 1
        output(seal(kind: Self.ack, sequence: sequence, payload))
    }

    private func acknowledged(_ payload: [UInt8]) {
        guard payload.count >= 8, (payload.count - 8) % 16 == 0 else { return }
        let now = Date()
        var acked = 0
        var latest: UInt64 = 0
        func done(_ sequence: UInt64) {
            guard let sent = outstanding.removeValue(forKey: sequence) else { return }
            holes.remove(sequence)
            acked += 1
            latest = max(latest, sequence)
            // (Only a frame sent once says how long a round trip takes.)
            if !sent.resent { measured(now.timeIntervalSince(sent.sentAt), at: now) }
        }
        // All up to this.
        let upTo = min(Self.be64(payload, 0), nextSequence - 1)
        if oldest <= upTo { for sequence in oldest ... upTo { done(sequence) } }
        // The ranges after it: what's new above the highest heard of before, and frames that were sent again.
        let before = highestAcked
        highestAcked = max(highestAcked, upTo)
        var heard: [ClosedRange<UInt64>] = []
        for i in stride(from: 8, to: payload.count, by: 16) {
            let from = Self.be64(payload, i), to = Self.be64(payload, i + 8)
            guard from <= to, to < nextSequence else { continue }
            heard.append(from ... to)
            if to > before { for sequence in max(from, before + 1) ... to { done(sequence) } }
            highestAcked = max(highestAcked, to)
        }
        for hole in holes where heard.contains(where: { $0.contains(hole) }) { done(hole) }
        while oldest < nextSequence, outstanding[oldest] == nil { oldest += 1 }
        // Three or more after a frame have arrived, and it hasn't: lost, sent again now (once, till its timeout).
        if highestAcked > 3 {
            let behind = highestAcked - 2
            if max(scanned, oldest) < behind {
                for sequence in max(scanned, oldest) ..< behind {
                    guard let sent = outstanding[sequence], !sent.resent else { continue }
                    outstanding[sequence]?.resent = true
                    outstanding[sequence]?.due = now.addingTimeInterval(timeout)
                    output(sent.frame)
                    holes.insert(sequence)
                    round.lost += 1
                }
            }
            scanned = max(scanned, behind)
        }
        if acked > 0 { grow(acked, latest: latest, at: now) }
        pump()
    }

    /// The window after frames are acknowledged: one more each while starting (so it doubles every round trip);
    /// at each round trip's end, the link's rate measured, and the window set from it.
    private func grow(_ acked: Int, latest: UInt64, at now: Date) {
        round.acked += acked
        if startup { window = min(Self.maximumWindow, window + Double(acked)) }
        guard latest >= round.sequence else { return }
        let elapsed = now.timeIntervalSince(round.at)
        let heavyLoss = round.lost * 5 > round.acked
        if elapsed > 0, !round.limited, !heavyLoss {
            rates.append(Double(round.acked) / elapsed)
            if rates.count > 10 { rates.removeFirst() }
        }
        let best = rates.max() ?? 0
        if startup {
            // Still growing by a quarter each round trip: there's more to find. Three times not, or heavy loss: found.
            if best > startupBest * 1.25 {
                startupBest = best
                startupStalls = 0
            } else if !round.limited {
                startupStalls += 1
            }
            // (A round trip half again as long as the link's own: a queue's filling, so its rate's been found.)
            let queueing = (smoothed ?? 0) > 1.5 * (shortest?.trip ?? .infinity) + 0.005
            if startupStalls >= 3 || heavyLoss || queueing { startup = false }
        }
        if !startup, best > 0, let trip = shortest?.trip ?? smoothed {
            window = min(Self.maximumWindow, max(Self.minimumWindow, 2 * best * trip))
        }
        // A fifth or more lost: a link swamped (or one that's changed), not the odd frame: fewer in flight.
        if heavyLoss, !round.timedOut { window = max(Self.minimumWindow, window * 0.7) }
        round = Round(sequence: nextSequence, at: now)
    }

    private func measured(_ trip: Double, at now: Date) {
        if let smoothed {
            variation = 0.75 * variation + 0.25 * abs(smoothed - trip)
            self.smoothed = 0.875 * smoothed + 0.125 * trip
        } else {
            smoothed = trip
            variation = trip / 2
        }
        // The shortest of the last ten seconds (a path that's changed has a new one).
        if let shortest, shortest.trip <= trip, now.timeIntervalSince(shortest.at) < 10 { return }
        shortest = (trip, now)
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
