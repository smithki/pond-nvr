import Foundation
import Testing
@testable import Remote
import Traversal

@Suite struct DiagnosisTests {
    func facts(public learned: Bool = true, changesPort: Bool? = false, ipv6: Bool = false) -> NetworkFacts {
        var f = NetworkFacts()
        f.learnedPublic = learned
        f.changesPort = changesPort
        f.globalIPv6 = ipv6
        return f
    }

    var nothingWorked: PathFinder.Report { PathFinder.Report(checked: 4, worked: 0) }

    @Test func bothSymmetric() {
        let why = Diagnosis.explain(mine: facts(changesPort: true), theirs: facts(changesPort: true), report: nothingWorked, peer: "Home")
        #expect(why.hasPrefix("Both ends are behind routers that show the world a new port"))
        #expect(why.contains("turn on IPv6 at this Mac's router") && why.contains("turn on IPv6 at Home's router"))
        #expect(why.contains("forward a UDP port") && why.contains("relay"))
    }

    @Test func oneSymmetricSaysWhich() {
        let mine = Diagnosis.explain(mine: facts(changesPort: true), theirs: facts(), report: nothingWorked, peer: "Home")
        #expect(mine.hasPrefix("This Mac is behind a router that shows the world a new port"))
        let theirs = Diagnosis.explain(mine: facts(), theirs: facts(changesPort: true), report: nothingWorked, peer: "Home")
        #expect(theirs.hasPrefix("Home is behind a router that shows the world a new port"))
    }

    @Test func stunUnansweredIsSaid() {
        let why = Diagnosis.explain(mine: facts(public: false, changesPort: nil), theirs: facts(), report: nothingWorked, peer: "Home")
        #expect(why.hasPrefix("This Mac couldn't learn its public address"))
    }

    @Test func ipv6OnBothPointsAtAFirewall() {
        let why = Diagnosis.explain(mine: facts(ipv6: true), theirs: facts(ipv6: true), report: nothingWorked, peer: "Home")
        #expect(why.contains("IPv6 firewall"))
        #expect(!why.contains("turn on IPv6"))
    }

    @Test func nothingHeardOrNoAnswersBack() {
        let unheard = Diagnosis.explain(mine: facts(), theirs: facts(), report: nothingWorked, peer: "Home")
        #expect(unheard.hasPrefix("None of Home's checks reached this Mac"))
        var heard = nothingWorked
        heard.heardFromPeer = true
        #expect(Diagnosis.explain(mine: facts(), theirs: facts(), report: heard, peer: "Home").hasPrefix("Home's checks reached this Mac"))
    }

    @Test func aMeshWithoutAnAddress() {
        var mine = NetworkFacts()
        mine.mesh = true
        let why = Diagnosis.explain(mine: mine, theirs: nil, report: nothingWorked, peer: "Home")
        #expect(why.hasPrefix("This Mac has no address in the mesh"))
        #expect(!why.contains("use a mesh"))
    }

    @Test func aLostConnectionSaysSoFirst() {
        var lost = PathFinder.Report(checked: 1, worked: 1)
        lost.lost = true
        #expect(Diagnosis.explain(mine: facts(), theirs: facts(), report: lost, peer: "Home").hasPrefix("The connection was made, then lost"))
    }

    @Test func aRelayThatGaveNoAddressSaysWhy() {
        var mine = facts()
        mine.relay = true
        mine.relayProblem = "the relay refused this Mac's credentials (is the secret right?)"
        let why = Diagnosis.explain(mine: mine, theirs: facts(), report: nothingWorked, peer: "Home")
        #expect(why.contains("This Mac's relay gave it no address: the relay refused this Mac's credentials"))
        #expect(why.contains("check the relay") && !why.contains("run a relay of your own"))
    }

    @Test func aRelaySetIsntSuggested() {
        var mine = facts(changesPort: true)
        mine.relay = true
        let why = Diagnosis.explain(mine: mine, theirs: facts(changesPort: true), report: nothingWorked, peer: "Home")
        #expect(!why.contains("run a relay of your own"))
    }
}
