import CryptoKit
import Foundation
import PondCore
import PondProtocol
import Testing
@testable import Remote

@Suite struct RemoteIdentityTests {
    @Test func anIdentityIsMadeOnceAndKept() throws {
        let keys = RemoteKeys(store: MemoryCredentialStore())
        let first = try keys.identity(name: "Home")
        let again = try keys.identity(name: "Home")
        #expect(first.peer == again.peer)
        // Its mailbox is the hash of its secret: what it shows the signaling service, to collect from it.
        #expect(RemoteIdentity.mailbox(of: first.mailboxSecret) == first.peer.mailbox)
        #expect(first.peer.id.count == 16)
    }

    @Test func peersAreKeptAddedAgainAndRemoved() throws {
        let keys = RemoteKeys(store: MemoryCredentialStore())
        var phone = RemoteIdentity(name: "Phone").peer
        try keys.add(phone)
        phone.name = "Kitchen iPad"
        try keys.add(phone)
        #expect(keys.peers() == [phone])
        try keys.remove(phone.id)
        #expect(keys.peers().isEmpty)
    }
}

@Suite struct EnvelopeTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let home = RemoteIdentity(name: "Home"), phone = RemoteIdentity(name: "Phone"), stranger = RemoteIdentity(name: "Stranger")

    @Test func itOpensForItsRecipientWithItsSender() throws {
        let envelope = try Envelope.seal(kind: "offer", body: Data("hello".utf8), from: phone, to: home.peer, now: Self.t0)
        let opened = try envelope.open(as: home, replay: ReplayGuard(), known: [phone.peer], now: Self.t0)
        #expect(opened.kind == "offer" && opened.body == Data("hello".utf8) && opened.sender == phone.peer.signingKey)
        // What the service sees: the mailbox, and bytes without the message in them.
        #expect(envelope.to == home.peer.mailbox)
        #expect(envelope.sealed.range(of: Data("hello".utf8)) == nil && envelope.sealed.range(of: Data("offer".utf8)) == nil)
    }

    @Test func noOneElseCanOpenIt() throws {
        let envelope = try Envelope.seal(kind: "offer", body: Data(), from: phone, to: home.peer, now: Self.t0)
        #expect(throws: Envelope.Failure.notForMe) { try envelope.open(as: stranger, replay: ReplayGuard(), known: [phone.peer], now: Self.t0) }
        // Readdressed to the stranger's mailbox: still sealed to the home's key.
        let readdressed = Envelope(to: stranger.peer.mailbox, sealed: envelope.sealed)
        #expect(throws: Envelope.Failure.unreadable) { try readdressed.open(as: stranger, replay: ReplayGuard(), known: [phone.peer], now: Self.t0) }
    }

    @Test func tamperedStaleReplayedOrUnknownIsRefused() throws {
        let envelope = try Envelope.seal(kind: "offer", body: Data("x".utf8), from: phone, to: home.peer, now: Self.t0)
        var tampered = envelope
        tampered.sealed[tampered.sealed.count - 1] ^= 1
        #expect(throws: Envelope.Failure.unreadable) { try tampered.open(as: home, replay: ReplayGuard(), known: [phone.peer], now: Self.t0) }
        #expect(throws: Envelope.Failure.stale) {
            try envelope.open(as: home, replay: ReplayGuard(), known: [phone.peer], now: Self.t0.addingTimeInterval(Envelope.window + 1))
        }
        let replay = ReplayGuard()
        _ = try envelope.open(as: home, replay: replay, known: [phone.peer], now: Self.t0)
        #expect(throws: Envelope.Failure.replayed) { try envelope.open(as: home, replay: replay, known: [phone.peer], now: Self.t0) }
        #expect(throws: Envelope.Failure.unknownSender) { try envelope.open(as: home, replay: ReplayGuard(), known: [], now: Self.t0) }
    }

    @Test func aStrangerMaySendOnlyWhatStrangersMay() throws {
        let envelope = try Envelope.seal(kind: "pair.request", body: Data(), from: stranger, to: home.peer, now: Self.t0)
        let opened = try envelope.open(as: home, replay: ReplayGuard(), strangers: ["pair.request"], known: [], now: Self.t0)
        #expect(opened.sender == stranger.peer.signingKey)
    }
}

@Suite struct PairingTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aDeviceIsPairedWithACode() throws {
        let homeKeys = RemoteKeys(store: MemoryCredentialStore())
        let home = try homeKeys.identity(name: "Home")
        let host = PairingHost(keys: homeKeys, identity: home)
        let code = host.newCode(signaling: "wss://signal.example", now: Self.t0)
        // Through text (a QR code) and back.
        let read = try #require(PairingCode(text: code.text))
        #expect(read == code)

        let phone = RemoteIdentity(name: "Phone")
        let request = try PairingGuest.request(read, from: phone, now: Self.t0)
        let opened = try request.open(as: home, replay: ReplayGuard(), strangers: ["pair.request"], known: homeKeys.peers(), now: Self.t0)
        let (device, answer) = try host.handle(opened.body, now: Self.t0)
        #expect(device == phone.peer && homeKeys.peers() == [phone.peer])

        let reply = try answer.open(as: phone, replay: ReplayGuard(), known: [code.pond], now: Self.t0)
        #expect(PairingGuest.accepted(kind: reply.kind, body: reply.body, sender: reply.sender, code: read) == home.peer)
    }

    @Test func aCodeIsUsedOnceAndOnlyWhileItsGood() throws {
        let keys = RemoteKeys(store: MemoryCredentialStore())
        let home = try keys.identity(name: "Home")
        let host = PairingHost(keys: keys, identity: home)
        let code = host.newCode(signaling: "wss://s", now: Self.t0)
        let body = { (me: RemoteIdentity) -> Data in
            let opened = try PairingGuest.request(code, from: me, now: Self.t0)
                .open(as: home, replay: ReplayGuard(), strangers: ["pair.request"], known: [], now: Self.t0)
            return opened.body
        }
        _ = try host.handle(try body(RemoteIdentity(name: "A")), now: Self.t0)
        #expect(throws: PairingHost.Failure.noSuchCode) { try host.handle(try body(RemoteIdentity(name: "B")), now: Self.t0) }

        let late = host.newCode(signaling: "wss://s", now: Self.t0)
        let lateBody = try PairingGuest.request(late, from: RemoteIdentity(name: "C"), now: Self.t0)
            .open(as: home, replay: ReplayGuard(), strangers: ["pair.request"], known: [], now: Self.t0).body
        #expect(throws: PairingHost.Failure.expired) { try host.handle(lateBody, now: Self.t0.addingTimeInterval(PairingHost.lifetime + 1)) }
    }

    @Test func aWrongSecretIsRefused() throws {
        let keys = RemoteKeys(store: MemoryCredentialStore())
        let home = try keys.identity(name: "Home")
        let host = PairingHost(keys: keys, identity: home)
        var forged = host.newCode(signaling: "wss://s", now: Self.t0)
        forged.secret = Data(repeating: 7, count: 16)
        let body = try PairingGuest.request(forged, from: RemoteIdentity(name: "Mallory"), now: Self.t0)
            .open(as: home, replay: ReplayGuard(), strangers: ["pair.request"], known: [], now: Self.t0).body
        #expect(throws: PairingHost.Failure.noSuchCode) { try host.handle(body, now: Self.t0) }
        #expect(keys.peers().isEmpty)
    }

    @Test func anAnswerFromAnotherPondIsntTaken() throws {
        let keys = RemoteKeys(store: MemoryCredentialStore())
        let home = try keys.identity(name: "Home")
        let code = PairingHost(keys: keys, identity: home).newCode(signaling: "wss://s", now: Self.t0)
        let impostor = RemoteIdentity(name: "Home")
        let phone = RemoteIdentity(name: "Phone")
        let fake = try Envelope.seal(kind: "pair.accepted", body: try JSONEncoder().encode(PairingMessage.Accepted(pond: impostor.peer)),
                                     from: impostor, to: phone.peer, now: Self.t0)
        let opened = try fake.open(as: phone, replay: ReplayGuard(), strangers: ["pair.accepted"], known: [], now: Self.t0)
        #expect(PairingGuest.accepted(kind: opened.kind, body: opened.body, sender: opened.sender, code: code) == nil)
    }
}
