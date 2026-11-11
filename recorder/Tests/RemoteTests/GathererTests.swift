import Foundation
import Testing
@testable import Remote
import Traversal

@Suite struct GathererTests {
    @Test func onlyWhatsWorthOffering() {
        let found = Gatherer.hosts(port: 4000)
        // (What this Mac has, by kind only: its addresses aren't for the log.)
        print("gathered: \(found.filter { !$0.address.isIPv6 }.count) IPv4, \(found.filter(\.address.isIPv6).count) IPv6")
        for candidate in found {
            #expect(candidate.kind == .host && candidate.address.port == 4000)
            if candidate.address.isIPv6 {
                // Global only (no link-local fe80::, no unique-local fc00::/7).
                #expect(candidate.address.ip[0] & 0xE0 == 0x20)
            } else {
                #expect(candidate.address.ip[0] != 127 && !(candidate.address.ip[0] == 169 && candidate.address.ip[1] == 254))
            }
        }
        // Every IPv6 one is a temporary address (the stable one never offered).
        let temporary = Gatherer.interfaces().filter { $0.name.hasPrefix("en") && $0.ip.count == 16 && Gatherer.temporary($0) }
        #expect(Set(found.filter(\.address.isIPv6).map(\.address.ip)) == Set(temporary.filter { $0.ip[0] & 0xE0 == 0x20 }.map(\.ip)))
    }

    @Test func meshModeOffersOnlyTheTunnel() {
        let found = Gatherer.hosts(port: 4000, mode: .mesh(subnets: Gatherer.tailnet))
        #expect(found.allSatisfy { c in Gatherer.tailnet.contains { $0.contains(c.address.ip) } })
    }

    @Test func subnets() throws {
        let tailnet = try #require(Subnet("100.64.0.0/10"))
        #expect(tailnet.contains([100, 64, 0, 1]) && tailnet.contains([100, 127, 255, 255]))
        #expect(!tailnet.contains([100, 128, 0, 1]) && !tailnet.contains([192, 168, 1, 1]))
        let v6 = try #require(Subnet("fd7a:115c:a1e0::/48"))
        #expect(v6.contains(try #require(STUNAddress("[fd7a:115c:a1e0:ab12::1]:0")).ip))
        #expect(!v6.contains(try #require(STUNAddress("[fd7a:115c:a1e1::1]:0")).ip))
        #expect(Subnet("nonsense") == nil && Subnet("10.0.0.0/33") == nil)
    }

    @Test func stunServersAreLookedUp() throws {
        #expect(PathSessions.resolve("127.0.0.1") == [STUNAddress(ip: [127, 0, 0, 1], port: 3478)])
        #expect(PathSessions.resolve("127.0.0.1:5000") == [STUNAddress(ip: [127, 0, 0, 1], port: 5000)])
        let loopback6 = try #require(STUNAddress("[::1]:5000"))
        #expect(PathSessions.resolve("[::1]:5000") == [loopback6])
        #expect(PathSessions.resolve("::1").first?.port == 3478)
        #expect(PathSessions.resolve("localhost").contains(STUNAddress(ip: [127, 0, 0, 1], port: 3478)))
        #expect(PathSessions.resolve("no-such-host.invalid").isEmpty)
    }
}
