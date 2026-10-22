import Foundation
import Testing
@testable import Traversal

@Suite struct PathFinderTests {
    /// Two agents, home (controlling) and away, each told the other's credentials and candidates (its host ones, and
    /// its public one from `stun`, if given), then started; their states once both have settled.
    static func connect(_ home: PacketTransport, homeHost: [UInt8], _ away: PacketTransport, awayHost: [UInt8],
                        stun: STUNAddress? = nil, relay: (address: STUNAddress, secret: String)? = nil, timing: PathFinder.Timing = fast,
                        settle: Double = 8) async -> (home: PathFinder.State, away: PathFinder.State, agents: (PathFinder, PathFinder)) {
        let a = PathFinder(role: .controlling, transport: home, timing: timing)
        let b = PathFinder(role: .controlled, transport: away, timing: timing)
        func candidates(_ agent: PathFinder, _ transport: PacketTransport, _ ip: [UInt8]) async -> [Candidate] {
            var found = [Candidate(kind: .host, address: STUNAddress(ip: ip, port: transport.port))]
            if let stun, let seen = await agent.probe(stun, timeout: 1), seen != found[0].address {
                found.append(Candidate(kind: .srflx, address: seen))
            }
            if let relay {
                let (username, password) = TURNClient.credentials(secret: relay.secret, name: "test")
                if let (relayed, _) = await agent.allocate(.init(address: relay.address, username: username, password: password)) {
                    found.append(relayed)
                }
            }
            return found
        }
        let mine = await candidates(a, home, homeHost), theirs = await candidates(b, away, awayHost)
        a.addLocal(mine)
        b.addLocal(theirs)
        a.setRemote(b.local, candidates: theirs)
        b.setRemote(a.local, candidates: mine)
        a.start()
        b.start()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            if settled(a.state) && settled(b.state) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (a.state, b.state, (a, b))
    }

    static func settled(_ state: PathFinder.State) -> Bool {
        switch state {
        case .connected, .failed, .closed: true
        default: false
        }
    }

    static var fast: PathFinder.Timing {
        var t = PathFinder.Timing()
        t.giveUp = 3
        return t
    }

    static func pair(_ state: PathFinder.State) -> CandidatePair? {
        if case let .connected(pair) = state { return pair }
        return nil
    }

    // MARK: Real sockets

    @Test func twoAgentsOnThisMacConnectOverIPv4() async throws {
        let (home, away) = (try UDPSocket(), try UDPSocket())
        let (h, a, agents) = await Self.connect(home, homeHost: [127, 0, 0, 1], away, awayHost: [127, 0, 0, 1])
        defer { agents.0.close(); agents.1.close() }
        let chosen = try #require(Self.pair(h))
        #expect(Self.pair(a) != nil)
        #expect(chosen.remote.address.port == away.port)

        // Bytes both ways on the chosen pair.
        final class Got: @unchecked Sendable { let lock = NSLock(); var bytes: [[UInt8]] = [] }
        let got = Got()
        agents.1.received = { b in got.lock.withLock { got.bytes.append(b) } }
        agents.0.send([0x80, 1, 2, 3])
        for _ in 0 ..< 50 where got.lock.withLock({ got.bytes.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got.lock.withLock { got.bytes } == [[0x80, 1, 2, 3]])
    }

    @Test func twoAgentsOnThisMacConnectOverIPv6() async throws {
        let (home, away) = (try UDPSocket(), try UDPSocket())
        let loopback: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let (h, a, agents) = await Self.connect(home, homeHost: loopback, away, awayHost: loopback)
        defer { agents.0.close(); agents.1.close() }
        #expect(Self.pair(h)?.remote.address.isIPv6 == true)
        #expect(Self.pair(a) != nil)
    }

    // MARK: Through routers

    @Test func bothBehindHomeRoutersConnectThroughTheirPublicAddresses() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let awayRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 20], mapping: .endpointIndependent, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: awayRouter)
        let (h, a, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { agents.0.close(); agents.1.close() }
        // Each other's private addresses can't be reached; their routers' can, once each has sent to the other.
        #expect(Self.pair(h)?.remote.address.ip == [203, 0, 113, 20])
        #expect(Self.pair(a)?.remote.address.ip == [203, 0, 113, 10])
    }

    @Test func oneBehindASymmetricRouterIsReachedByWhatItSends() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        // The home router lets in any port of an address it has sent to (as many do).
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .address)
        let carrier = FakeNetwork.Router(publicIP: [100, 64, 0, 1], mapping: .perDestination, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: carrier)
        let (h, a, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { agents.0.close(); agents.1.close() }
        // The away side's public port for the home side isn't the one STUN saw: the home side learns it from the
        // away side's own checks (peer-reflexive).
        let chosen = try #require(Self.pair(h))
        #expect(chosen.remote.kind == .prflx && chosen.remote.address.ip == [100, 64, 0, 1])
        #expect(Self.pair(a) != nil)
    }

    @Test func aSymmetricRouterAndAStrictOneCantMeet() async throws {
        // The symmetric side sends from a new port for each address; the home router lets in only exactly what it has
        // sent to, which is never that port. No direct path: a relay's work (or IPv6, or a forwarded port).
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let carrier = FakeNetwork.Router(publicIP: [100, 64, 0, 1], mapping: .perDestination, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: carrier)
        let (h, _, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { agents.0.close(); agents.1.close() }
        guard case let .failed(report) = h else { Issue.record("home: \(h)"); return }
        #expect(!report.heardFromPeer && report.worked == 0)
    }

    @Test func bothSymmetricFailsAndSaysWhatItSaw() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let one = FakeNetwork.Router(publicIP: [100, 64, 0, 1], mapping: .perDestination, filtering: .addressAndPort)
        let other = FakeNetwork.Router(publicIP: [100, 64, 0, 2], mapping: .perDestination, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: one), away = net.host([10, 0, 0, 7], behind: other)
        let (h, a, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { agents.0.close(); agents.1.close() }
        guard case let .failed(report) = h else { Issue.record("home: \(h)"); return }
        #expect(report.checked > 0 && report.worked == 0 && !report.lost)
        guard case .failed = a else { Issue.record("away: \(a)"); return }
    }

    @Test func onTheSameNetworkTheirOwnAddressesAreUsed() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let router = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: router), away = net.host([192, 168, 1, 9], behind: router)
        let (h, _, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { agents.0.close(); agents.1.close() }
        let chosen = try #require(Self.pair(h))
        #expect(chosen.remote.kind == .host && chosen.remote.address.ip == [192, 168, 1, 9])
    }

    @Test func aLossyNetworkStillConnects() async throws {
        let net = FakeNetwork()
        net.loss = 0.3
        let stun = net.stunServer([198, 51, 100, 1])
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let awayRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 20], mapping: .endpointIndependent, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: awayRouter)
        // (With a third of the packets lost, checks take their retries: the real time limit, not the tests' short one.)
        let (h, a, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun,
                                                timing: PathFinder.Timing(), settle: 16)
        defer { agents.0.close(); agents.1.close() }
        #expect(Self.pair(h) != nil, "home: \(h)")
        #expect(Self.pair(a) != nil, "away: \(a)")
    }

    @Test func aConnectionThatGoesQuietIsLost() async throws {
        let net = FakeNetwork()
        let router = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: router), away = net.host([192, 168, 1, 9], behind: router)
        var timing = Self.fast
        timing.keepAlive = 0.1
        timing.lostAfter = 0.6
        let (h, _, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, timing: timing)
        defer { agents.0.close(); agents.1.close() }
        #expect(Self.pair(h) != nil)
        // The network goes away: nothing answers the checks that keep it.
        net.lock.withLock { net.cut = true }
        for _ in 0 ..< 100 where Self.pair(agents.0.state) != nil { try await Task.sleep(for: .milliseconds(20)) }
        guard case let .failed(report) = agents.0.state else { Issue.record("still \(agents.0.state)"); return }
        #expect(report.lost)
    }

    @Test func checksSignedWithTheWrongPasswordGoUnanswered() async throws {
        let net = FakeNetwork()
        let router = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .open)
        let home = net.host([192, 168, 1, 5], behind: router), away = net.host([192, 168, 1, 9], behind: router)
        let a = PathFinder(role: .controlling, transport: home, timing: Self.fast)
        let b = PathFinder(role: .controlled, transport: away, timing: Self.fast)
        defer { a.close(); b.close() }
        a.addLocal([Candidate(kind: .host, address: home.address)])
        b.addLocal([Candidate(kind: .host, address: away.address)])
        // The home side has the away side's username, and a password that isn't its own.
        a.setRemote(.init(ufrag: b.local.ufrag, password: "not the password at all!"), candidates: [Candidate(kind: .host, address: away.address)])
        b.setRemote(a.local, candidates: [Candidate(kind: .host, address: home.address)])
        a.start()
        b.start()
        try await Task.sleep(for: .seconds(1.5))
        #expect(Self.pair(a.state) == nil && Self.pair(b.state) == nil)
    }

    @Test func aRestartFollowsAMoveToAnotherNetwork() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let wifi = FakeNetwork.Router(publicIP: [203, 0, 113, 20], mapping: .endpointIndependent, filtering: .addressAndPort)
        let cellular = FakeNetwork.Router(publicIP: [100, 64, 9, 9], mapping: .endpointIndependent, filtering: .address)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: wifi)
        let (h, _, (a, b)) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun)
        defer { a.close(); b.close() }
        #expect(Self.pair(h)?.remote.address.ip == [203, 0, 113, 20])
        final class Got: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let got = Got()
        a.received = { _ in got.lock.withLock { got.count += 1 } }

        // The away side moves to cellular: both restart, and tell each other their new credentials and candidates.
        away.move(to: [10, 200, 0, 3], behind: cellular)
        let awayCredentials = b.restart(), homeCredentials = a.restart()
        let awayHost = [Candidate(kind: .host, address: away.address)]
        var awayAll = awayHost
        if let seen = await b.probe(stun) { awayAll.append(Candidate(kind: .srflx, address: seen)) }
        let homeAll = [Candidate(kind: .host, address: home.address)] + [await a.probe(stun)].compactMap { $0 }.map { Candidate(kind: .srflx, address: $0) }
        b.addLocal(awayHost)
        a.addLocal([Candidate(kind: .host, address: home.address)])
        a.setRemote(awayCredentials, candidates: awayAll)
        b.setRemote(homeCredentials, candidates: homeAll)
        for _ in 0 ..< 200 where Self.pair(a.state)?.remote.address.ip != [100, 64, 9, 9] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Self.pair(a.state)?.remote.address.ip == [100, 64, 9, 9])
        #expect(Self.pair(b.state) != nil)
        // And what's sent goes the new way.
        b.send([0x80, 9])
        for _ in 0 ..< 50 where got.lock.withLock({ got.count == 0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got.lock.withLock { got.count } == 1)
    }

    @Test func askingAtTwoPortsTellsASymmetricRouter() async throws {
        let net = FakeNetwork()
        let first = net.stunServer([198, 51, 100, 1]), second = net.stunServer([198, 51, 100, 1])
        #expect(second.port == first.port + 1)
        for (n, (mapping, changes)) in [(FakeNetwork.Mapping.endpointIndependent, false), (.perDestination, true)].enumerated() {
            let router = FakeNetwork.Router(publicIP: [203, 0, 113, UInt8(10 + n)], mapping: mapping, filtering: .addressAndPort)
            let finder = PathFinder(role: .controlled, transport: net.host([192, 168, 1, 5], behind: router))
            defer { finder.close() }
            let a = try #require(await finder.probe(first)), b = try #require(await finder.probe(second))
            #expect(a.ip == b.ip && (a.port != b.port) == changes)
        }
    }

    // MARK: Through a relay

    @Test func bothSymmetricConnectThroughARelayOfTheirOwn() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let relay = net.relay([198, 51, 100, 2], secret: "shared secret")
        let one = FakeNetwork.Router(publicIP: [100, 64, 0, 1], mapping: .perDestination, filtering: .addressAndPort)
        let other = FakeNetwork.Router(publicIP: [100, 64, 0, 2], mapping: .perDestination, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: one), away = net.host([10, 0, 0, 7], behind: other)
        let (h, a, (homeFinder, awayFinder)) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun,
                                                                   relay: (relay.address, "shared secret"))
        defer { homeFinder.close(); awayFinder.close() }
        let chosen = try #require(Self.pair(h), "home: \(h)")
        #expect(Self.pair(a) != nil, "away: \(a)")
        #expect(chosen.local.kind == .relay || chosen.remote.kind == .relay)
        // What's sent goes through it, both ways.
        final class Got: @unchecked Sendable { let lock = NSLock(); var bytes: [[UInt8]] = [] }
        let atHome = Got(), away_ = Got()
        homeFinder.received = { b in atHome.lock.withLock { atHome.bytes.append(b) } }
        awayFinder.received = { b in away_.lock.withLock { away_.bytes.append(b) } }
        homeFinder.send([0x80, 1])
        awayFinder.send([0x80, 2])
        for _ in 0 ..< 100 where atHome.lock.withLock({ atHome.bytes.isEmpty }) || away_.lock.withLock({ away_.bytes.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(atHome.lock.withLock { atHome.bytes } == [[0x80, 2]] && away_.lock.withLock { away_.bytes } == [[0x80, 1]])
    }

    @Test func aWrongSecretIsRefusedAndSaysSo() async throws {
        let net = FakeNetwork()
        let relay = net.relay([198, 51, 100, 2], secret: "the right one")
        let finder = PathFinder(role: .controlled, transport: net.host([203, 0, 113, 9]))
        defer { finder.close() }
        let (username, password) = TURNClient.credentials(secret: "a wrong one", name: "test")
        #expect(await finder.allocate(.init(address: relay.address, username: username, password: password)) == nil)
        #expect(finder.relayProblem?.contains("credentials") == true)
        #expect(relay.lock.withLock { relay.refused } >= 1)
    }

    @Test func aDirectPathIsChosenOverTheRelay() async throws {
        let net = FakeNetwork()
        let stun = net.stunServer([198, 51, 100, 1])
        let relay = net.relay([198, 51, 100, 2], secret: "s")
        let homeRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 10], mapping: .endpointIndependent, filtering: .addressAndPort)
        let awayRouter = FakeNetwork.Router(publicIP: [203, 0, 113, 20], mapping: .endpointIndependent, filtering: .addressAndPort)
        let home = net.host([192, 168, 1, 5], behind: homeRouter), away = net.host([10, 0, 0, 7], behind: awayRouter)
        let (h, _, agents) = await Self.connect(home, homeHost: home.ip, away, awayHost: away.ip, stun: stun, relay: (relay.address, "s"))
        defer { agents.0.close(); agents.1.close() }
        let chosen = try #require(Self.pair(h), "home: \(h)")
        #expect(chosen.local.kind != .relay && chosen.remote.kind != .relay)
    }

    @Test func coturnsCredentials() {
        // username "expiry:name", password base64(HMAC-SHA1(secret, username)).
        let (username, password) = TURNClient.credentials(secret: "secret", name: "pond", lifetime: 100, now: Date(timeIntervalSince1970: 1000))
        #expect(username == "1100:pond")
        #expect(password == Data(Hashes.hmac(Array("secret".utf8), Array("1100:pond".utf8))).base64EncodedString())
    }

    // MARK: Pieces

    @Test func prioritiesAsRFC8445HasThem() {
        let v4 = STUNAddress(ip: [192, 168, 1, 5], port: 4000), v6 = STUNAddress(ip: [UInt8](repeating: 0x20, count: 16), port: 4000)
        #expect(Candidate.priority(.host, v4) == 126 << 24 | 65534 << 8 | 255)
        #expect(Candidate.priority(.host, v6) > Candidate.priority(.host, v4))
        #expect(Candidate.priority(.srflx, v6) < Candidate.priority(.host, v4))
        #expect(Candidate.priority(.relay, v6) < Candidate.priority(.srflx, v4))
        let pair = CandidatePair(local: Candidate(kind: .host, address: v4), remote: Candidate(kind: .srflx, address: v4))
        let g = UInt64(pair.local.priority), d = UInt64(pair.remote.priority)
        #expect(pair.priority(controlling: true) == (1 << 32) * min(g, d) + 2 * max(g, d) + 1)
    }

    @Test func addressesAsText() throws {
        #expect(STUNAddress("203.0.113.5:4000") == STUNAddress(ip: [203, 0, 113, 5], port: 4000))
        let v6 = try #require(STUNAddress("[2001:db8::1]:443"))
        #expect(v6.ip == [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1] && v6.port == 443)
        #expect(STUNAddress(v6.description) == v6)
        #expect(STUNAddress("nonsense") == nil && STUNAddress("1.2.3:4") == nil)
        let decoded = try JSONDecoder().decode([Candidate].self, from: JSONEncoder().encode([Candidate(kind: .srflx, address: v6)]))
        #expect(decoded.first?.address == v6 && decoded.first?.kind == .srflx)
    }
}
