import Testing
@testable import PondCore

@Suite struct MacReadinessTests {
    static let miniPmset = """
    System-wide power settings:
    Currently in use:
     standby              0
     autorestart          1
     sleep                0 (sleep prevented by pond, powerd)
     displaysleep         10
     lowpowermode         0
    """

    static func power(_ pmset: String = miniPmset, battery: String = "Now drawing from 'AC Power'\n") -> MacPower {
        var p = MacPower()
        p.read(pmset: pmset, battery: battery)
        return p
    }

    @Test func aWellSetUpMacMiniHasNothingToSay() {
        var p = Self.power()
        p.logsInAutomatically = true
        #expect(p.restartsAfterPowerLoss == true && p.sleepMinutes == 0 && p.sleepHeldByPond && !p.isLaptop && !p.onBattery)
        #expect(MacReadiness.findings(p, recording: true).isEmpty)
    }

    @Test func sleepingWithoutPondHoldingItOff() {
        var p = Self.power(Self.miniPmset.replacingOccurrences(of: "sleep                0 (sleep prevented by pond, powerd)",
                                                               with: "sleep                10 (sleep prevented by powerd)"))
        p.logsInAutomatically = true
        #expect(p.sleepMinutes == 10 && !p.sleepHeldByPond)
        #expect(MacReadiness.findings(p, recording: true).map(\.kind) == [.mayIdleSleep])
        // Not recording: nothing to keep awake for.
        #expect(MacReadiness.findings(p, recording: false).isEmpty)
    }

    @Test func noRestartAfterAPowerCut() {
        var p = Self.power(Self.miniPmset.replacingOccurrences(of: "autorestart          1", with: "autorestart          0"))
        p.logsInAutomatically = true
        #expect(MacReadiness.findings(p, recording: true).map(\.kind) == [.noRestartAfterPowerLoss])
    }

    @Test func waitingForLoginSaysWhy() {
        var p = Self.power()
        p.fileVault = true
        let finding = MacReadiness.findings(p, recording: true).first
        #expect(finding?.kind == .waitsForLogin && finding?.severity == .notice)
        #expect(finding?.evidence.hasPrefix("FileVault is on") == true && finding?.place == .privacy)
        p.fileVault = false
        #expect(MacReadiness.findings(p, recording: true).first?.place == .users)
    }

    @Test func laptopsAndBatteries() {
        let laptop = " -InternalBattery-0 (id=1234)\t100%; charged; 0:00 remaining present: true\n"
        var p = Self.power(battery: "Now drawing from 'AC Power'\n" + laptop)
        p.logsInAutomatically = true
        #expect(MacReadiness.findings(p, recording: true).map(\.kind) == [.laptop])
        p = Self.power(battery: "Now drawing from 'Battery Power'\n" + laptop)
        p.logsInAutomatically = true
        #expect(MacReadiness.findings(p, recording: true).map(\.kind) == [.onBattery])
        p = Self.power(battery: "Now drawing from 'UPS Power'\n -CyberPower (id=1)\t80%; discharging\n")
        p.logsInAutomatically = true
        #expect(MacReadiness.findings(p, recording: true).map(\.kind) == [.onUPS])
    }
}
