import Foundation
import NVRCore
import Testing
@testable import Devices

/// ONVIF's controls as cameras describe them: the replies' shapes (prefixes vary from make to make) read
/// into items, and only what a camera has.
@Suite struct ONVIFItemsTests {
    static func reply(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" \
        xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" \
        xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tmd="http://www.onvif.org/ver10/deviceIO/wsdl">
        <s:Body>\(body)</s:Body></s:Envelope>
        """)
    }

    @Test func imageSettingsAreThoseWithARange() throws {
        let options = try Self.reply("""
        <timg:GetOptionsResponse><timg:ImagingOptions>
          <tt:Brightness><tt:Min>0</tt:Min><tt:Max>255</tt:Max></tt:Brightness>
          <tt:ColorSaturation><tt:Min>0</tt:Min><tt:Max>100</tt:Max></tt:ColorSaturation>
          <tt:Contrast><tt:Min>50</tt:Min><tt:Max>50</tt:Max></tt:Contrast>
          <tt:IrCutFilterModes>AUTO</tt:IrCutFilterModes>
        </timg:ImagingOptions></timg:GetOptionsResponse>
        """)
        let ranges = ONVIFItems.ranges(in: options)
        // Contrast's range is a single value: it can't be changed. Sharpness isn't offered at all.
        #expect(ranges.map(\.id) == ["brightness", "saturation"])
        #expect(ranges[0].min == 0 && ranges[0].max == 255)
        #expect(ranges[1].element == "ColorSaturation" && ranges[1].max == 100)
    }

    static let outputConfiguration = """
    <trt:GetAudioOutputConfigurationsResponse>
      <trt:Configurations token="AudioOut_1">
        <tt:Name>Speaker</tt:Name><tt:UseCount>2</tt:UseCount><tt:OutputToken>AudioOutput_1</tt:OutputToken>
        <tt:SendPrimacy>www.onvif.org/ver20/HalfDuplex/Auto</tt:SendPrimacy><tt:OutputLevel>40</tt:OutputLevel>
      </trt:Configurations>
    </trt:GetAudioOutputConfigurationsResponse>
    """

    @Test func theSpeakersLevelIsItsOutputConfigurations() throws {
        let configuration = try #require(ONVIFItems.OutputConfiguration.parse(try Self.reply(Self.outputConfiguration)))
        #expect(configuration == ONVIFItems.OutputConfiguration(token: "AudioOut_1", name: "Speaker", useCount: "2",
                                                                outputToken: "AudioOutput_1",
                                                                sendPrimacy: "www.onvif.org/ver20/HalfDuplex/Auto", level: 40))
    }

    @Test func settingTheLevelSendsTheWholeConfigurationBack() throws {
        let configuration = try #require(ONVIFItems.OutputConfiguration.parse(try Self.reply(Self.outputConfiguration)))
        let xml = configuration.xml(level: 72.6)
        #expect(xml.contains("token=\"AudioOut_1\""))
        #expect(xml.contains("<OutputToken>AudioOutput_1</OutputToken>"))
        #expect(xml.contains("<SendPrimacy>www.onvif.org/ver20/HalfDuplex/Auto</SendPrimacy>"))
        #expect(xml.contains("<OutputLevel>73</OutputLevel>"))
    }

    @Test func aConfigurationWithoutALevelIsNone() throws {
        let reply = try Self.reply("""
        <trt:GetAudioOutputConfigurationsResponse><trt:Configurations token="a">
          <tt:OutputToken>o</tt:OutputToken></trt:Configurations></trt:GetAudioOutputConfigurationsResponse>
        """)
        #expect(ONVIFItems.OutputConfiguration.parse(reply) == nil)
    }

    @Test func toursAreNamedAndSayWhetherTheyAreTouring() throws {
        let reply = try Self.reply("""
        <tptz:GetPresetToursResponse>
          <tptz:PresetTour token="1"><tt:Name>Patrol</tt:Name><tt:Status><tt:State>Touring</tt:State></tt:Status></tptz:PresetTour>
          <tptz:PresetTour token="2"><tt:Name></tt:Name><tt:Status><tt:State>Idle</tt:State></tt:Status></tptz:PresetTour>
          <tptz:PresetTour><tt:Name>No token</tt:Name></tptz:PresetTour>
        </tptz:GetPresetToursResponse>
        """)
        #expect(ONVIFItems.tours(in: reply) == [
            ONVIFItems.Tour(token: "1", name: "Patrol", touring: true),
            // Unnamed: named by its token.
            ONVIFItems.Tour(token: "2", name: "Tour 2", touring: false),
        ])
    }

    @Test func relaysSayWhetherTheyStayAsSet() throws {
        let reply = try Self.reply("""
        <tmd:GetRelayOutputsResponse>
          <tmd:RelayOutputs token="Door"><tt:Properties><tt:Mode>Monostable</tt:Mode></tt:Properties></tmd:RelayOutputs>
          <tmd:RelayOutputs token="Light"><tt:Properties><tt:Mode>Bistable</tt:Mode></tt:Properties></tmd:RelayOutputs>
        </tmd:GetRelayOutputsResponse>
        """)
        #expect(ONVIFItems.relays(in: reply) == [
            ONVIFItems.Relay(token: "Door", bistable: false), ONVIFItems.Relay(token: "Light", bistable: true),
        ])
    }

    @Test func thePTZNodeSaysWhatMoves() throws {
        let reply = try Self.reply("""
        <tptz:GetNodesResponse><tptz:PTZNode token="n"><tt:SupportedPTZSpaces>
          <tt:ContinuousPanTiltVelocitySpace><tt:URI>x</tt:URI></tt:ContinuousPanTiltVelocitySpace>
        </tt:SupportedPTZSpaces><tt:MaximumNumberOfPresets>64</tt:MaximumNumberOfPresets>
        <tt:HomeSupported>false</tt:HomeSupported></tptz:PTZNode></tptz:GetNodesResponse>
        """)
        #expect(ONVIFPTZNode.parse(reply) == ONVIFPTZNode(panTilt: true, zoom: false, presets: 64))
    }

    @Test func presetsByToken() throws {
        let reply = try Self.reply("""
        <tptz:GetPresetsResponse>
          <tptz:Preset token="0"><tt:Name>Door</tt:Name></tptz:Preset>
          <tptz:Preset token="7"></tptz:Preset>
        </tptz:GetPresetsResponse>
        """)
        #expect(ONVIFPTZ.presets(in: reply) == [PTZPreset(id: "0", name: "Door"), PTZPreset(id: "7", name: "7")])
    }

    @Test func nightModeIsTheIRCutFilter() throws {
        // The filter on lets colour through (day); off, infrared (night).
        #expect(ONVIFNightMode.mode("ON") == .day && ONVIFNightMode.mode("off") == .night && ONVIFNightMode.mode("Auto") == .auto)
        #expect(ONVIFNightMode.mode("SOMETIMES") == nil)
        for mode in NightMode.allCases { #expect(ONVIFNightMode.mode(ONVIFNightMode.filter(mode)) == mode) }
        let options = try Self.reply("""
        <timg:GetOptionsResponse><timg:ImagingOptions>
          <tt:IrCutFilterModes>OFF</tt:IrCutFilterModes><tt:IrCutFilterModes>AUTO</tt:IrCutFilterModes>
        </timg:ImagingOptions></timg:GetOptionsResponse>
        """)
        // In Pond's order, whatever the camera's.
        #expect(ONVIFNightMode.choices(in: options) == [.auto, .night])
    }
}

@Suite struct ReolinkControlsTests {
    @Test func abilitiesAreThoseWithAVersion() {
        let ability = ReolinkAbility.parse(["Ability": [
            "supportAudioAlarm": ["permit": 0, "ver": 1],
            "abilityChn": [["ptzCtrl": ["permit": 6, "ver": 1], "isp": ["ver": 0]]],
        ]])
        #expect(ability?.has("ptzCtrl") == true)
        #expect(ability?.has("supportAudioAlarm") == true)
        #expect(ability?.has("isp") == false)
        #expect(ability?.has("absent") == false)
        #expect(ReolinkAbility.parse([:]) == nil)
    }

    @Test func movesAreOneDirectionAtASpeed() {
        #expect(ReolinkPTZ.operation(PTZVelocity(pan: 1)).map { [$0.op, String($0.speed)] } == ["Right", "64"])
        #expect(ReolinkPTZ.operation(PTZVelocity(pan: -0.5, tilt: 0.5)).map(\.op) == "LeftUp")
        #expect(ReolinkPTZ.operation(PTZVelocity(zoom: -0.6)).map(\.op) == "ZoomDec")
        // Too slight to be meant: a stop.
        #expect(ReolinkPTZ.operation(PTZVelocity(pan: 0.1)) == nil)
    }

    @Test func presetsAreTheEnabledOnes() {
        let presets = ReolinkPTZ.presets(in: ["PtzPreset": [
            ["id": 0, "enable": 1, "name": "Front door"],
            ["id": 1, "enable": 0, "name": ""],
            ["id": 2, "enable": 1],
        ]])
        #expect(presets == [PTZPreset(id: "0", name: "Front door"), PTZPreset(id: "2", name: "Position 3")])
    }

    @Test func dayAndNightAreTheISPs() {
        #expect(ReolinkNightMode.mode("Black&White") == .night && ReolinkNightMode.mode("color") == .day)
        for mode in NightMode.allCases { #expect(ReolinkNightMode.mode(ReolinkNightMode.value(mode)) == mode) }
    }

    @Test func irLightsAreAutoOrOff() {
        #expect(ReolinkIRLights.choice("Auto") == "auto" && ReolinkIRLights.choice("Off") == "off")
        #expect(ReolinkIRLights.choice("Sometimes") == nil)
        #expect(ReolinkIRLights(api: ReolinkAPI(host: "h", username: "u", password: "p")).item.group == .light)
    }

    @Test func mirrorAndFlipAreTheISPsSwitches() {
        let api = ReolinkAPI(host: "h", username: "u", password: "p")
        #expect(ReolinkISPSwitch.mirror(api).field == "mirroring" && ReolinkISPSwitch.mirror(api).item.id == "mirror")
        #expect(ReolinkISPSwitch.flip(api).field == "rotation" && ReolinkISPSwitch.flip(api).item.id == "flip")
        #expect(ReolinkISPSwitch.flip(api).item.group == .device)
    }

    @Test func tooManyLoginsIsBusyNotBroken() {
        #expect(ReolinkAPI.Failure.tooManyLogins.control == .busy)
        #expect(ReolinkAPI.Failure.unreachable.control == .unreachable)
    }
}

// MARK: - Which provider serves each control

/// An item that says what it is and which provider it came from; `refuses`: it says it can't when used.
struct FakeItem: ItemControl {
    let item: Config.Controls.Item
    var refuses = false

    init(_ id: String, provider: String, refuses: Bool = false, group: Config.Controls.Item.Group = .picture, order: Int = 0) {
        item = Config.Controls.Item(id: id, title: id, symbol: "circle", group: group, order: order, kind: .toggle, provider: provider)
        self.refuses = refuses
    }

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        if refuses { throw .notSupported }
        return .choice(item.provider)
    }
}

/// A provider whose items are fixed, and which counts how often it's asked.
final class ItemsProvider: CameraProvider, @unchecked Sendable {
    let id: String
    var name: String { id }
    let offer: Offer<[any ItemControl]>
    private let lock = NSLock()
    private var asked = 0
    var timesAsked: Int { lock.withLock { asked } }

    init(_ id: String, _ offer: Offer<[any ItemControl]>) {
        self.id = id
        self.offer = offer
    }

    func identify(host: String, username: String, password: String) async -> Config.Device? { nil }

    func items(_ access: CameraAccess) async -> Offer<[any ItemControl]> {
        lock.withLock { asked += 1 }
        return offer
    }
}

@Suite struct ControlResolutionTests {
    static let access = CameraAccess(host: "h", username: "u", password: "p")

    static func served(_ controls: CameraControls, _ id: String) async throws -> String? {
        let value = try await controls.withItem(id) { (control: any ItemControl) async throws(ControlFailure) -> Config.Controls.Value? in
            try await control.value()
        }
        if case let .choice(provider)? = value { return provider }
        return nil
    }

    @Test func eachItemComesFromTheFirstProviderThatHasIt() async throws {
        let own = ItemsProvider("own", .yes([FakeItem("dayNight", provider: "own"), FakeItem("volume", provider: "own", group: .sound)]))
        let onvif = ItemsProvider("onvif", .yes([FakeItem("dayNight", provider: "onvif"), FakeItem("brightness", provider: "onvif")]))
        let controls = CameraControls(access: Self.access, providers: [own, onvif])
        // One camera, mixing its make's own with ONVIF's.
        #expect(try await Self.served(controls, "dayNight") == "own")
        #expect(try await Self.served(controls, "brightness") == "onvif")
        // In their groups' order (picture before sound), then their own.
        #expect(await controls.items().map(\.item.id) == ["brightness", "dayNight", "volume"])
    }

    @Test func oneThatSaysItCantWhenUsedIsPassedOver() async throws {
        let own = ItemsProvider("own", .yes([FakeItem("volume", provider: "own", refuses: true)]))
        let onvif = ItemsProvider("onvif", .yes([FakeItem("volume", provider: "onvif")]))
        let controls = CameraControls(access: Self.access, providers: [own, onvif])
        #expect(try await Self.served(controls, "volume") == "onvif")
        // And stays passed over.
        #expect(try await Self.served(controls, "volume") == "onvif")
    }

    @Test func noneLeftIsNotSupported() async {
        let controls = CameraControls(access: Self.access, providers: [ItemsProvider("own", .yes([FakeItem("siren", provider: "own", refuses: true)]))])
        await #expect(throws: ControlFailure.notSupported) { try await Self.served(controls, "siren") }
        await #expect(throws: ControlFailure.notSupported) { try await Self.served(controls, "nothing") }
    }

    @Test func itemsAreAskedForOnce() async {
        let onvif = ItemsProvider("onvif", .yes([FakeItem("brightness", provider: "onvif")]))
        let controls = CameraControls(access: Self.access, providers: [onvif])
        _ = await controls.items()
        _ = await controls.items()
        #expect(onvif.timesAsked == 1)
    }

    @Test func aProviderThatCouldntBeAskedIsStoodInForNotForgotten() async throws {
        // The make's own API had too many logins open: ONVIF serves meanwhile, and the camera's own API is
        // asked again later (not passed over for good, as a "no" is).
        let own = ItemsProvider("own", .unknown)
        let onvif = ItemsProvider("onvif", .yes([FakeItem("dayNight", provider: "onvif")]))
        let controls = CameraControls(access: Self.access, providers: [own, onvif])
        #expect(try await Self.served(controls, "dayNight") == "onvif")
        #expect(await controls.retryPending)
        let declined = CameraControls(access: Self.access, providers: [ItemsProvider("own", .no), onvif])
        _ = await declined.items()
        #expect(await !declined.retryPending)
    }
}

@Suite struct ProviderOrderTests {
    @Test func theChosenProviderFirstThenTheOthersThatFit() {
        let viaONVIF = Config.Device(manufacturer: "Reolink", model: "E1 Pro", provider: "onvif")
        #expect(CameraProviders.order(for: viaONVIF).map(\.id) == ["onvif", "reolink"])
        let viaOwn = Config.Device(manufacturer: "Reolink", model: "E1 Pro", provider: "reolink")
        #expect(CameraProviders.order(for: viaOwn).map(\.id) == ["reolink", "onvif"])
    }

    @Test func aVideoOnlyCameraHasNoControls() {
        let video = Config.Device(manufacturer: "Reolink", model: "E1 Pro", provider: Config.Device.videoOnly)
        #expect(CameraProviders.order(for: video).isEmpty)
    }

    @Test func aCameraNotYetIdentifiedIsAskedOverONVIF() {
        #expect(CameraProviders.order(for: nil).map(\.id) == ["onvif"])
    }
}
