import Foundation
import PondCore
import Testing
@testable import Devices

@Suite struct ReolinkProviderTests {
    /// GetDevInfo as a Reolink E1 Pro answers it (serial made up).
    nonisolated(unsafe) static let e1Pro: [String: Any] = [
        "model": "E1 Pro", "serial": "100000000000001", "firmVer": "v3.1.0.4417_2412122130",
        "exactType": "WIFI_SOLO_IPC", "type": "IPC", "name": "Front Door", "itemNo": "E Series E330",
    ]

    @Test func aCameraFromItsDevInfo() {
        let device = ReolinkProvider.device(fromDevInfo: Self.e1Pro)
        #expect(device == Config.Device(manufacturer: "Reolink", model: "E1 Pro", serial: "100000000000001",
                                        firmware: "v3.1.0.4417_2412122130", isDoorbell: false, provider: "reolink"))
    }

    @Test func aDoorbellByItsTypeOrModel() {
        var info = Self.e1Pro
        info["exactType"] = "WIFI_DOORBELL"
        #expect(ReolinkProvider.device(fromDevInfo: info)?.isDoorbell == true)
        info = Self.e1Pro
        info["model"] = "Reolink Video Doorbell WiFi"
        #expect(ReolinkProvider.device(fromDevInfo: info)?.isDoorbell == true)
    }

    @Test func noModelNoDevice() {
        #expect(ReolinkProvider.device(fromDevInfo: ["serial": "1"]) == nil)
        #expect(ReolinkProvider.device(fromDevInfo: ["model": "  "]) == nil)
    }

    @Test func reolinkStreamAddresses() {
        let s = ReolinkProvider().streams(host: "10.0.0.5")
        #expect(s?.main == "rtsp://10.0.0.5:554/h264Preview_01_main")
        #expect(s?.sub == "rtsp://10.0.0.5:554/h264Preview_01_sub")
    }
}

@Suite struct ONVIFTests {
    @Test func passwordDigestAsTheStandardHasIt() {
        let created = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        let xml = ONVIF.envelope("<x/>", username: "admin", password: "secret", nonce: Array(0 ..< 16), created: created)
        // Base64(SHA-1(nonce + created + password)), computed independently.
        #expect(xml.contains(">y4jAm2YZVSBC5qc60rTh/ZebPnI=</Password>"))
        #expect(xml.contains("<Created xmlns=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">2026-10-14T12:00:00Z</Created>"))
        #expect(xml.contains("<s:Body><x/></s:Body>"))
    }

    @Test func valuesWhateverTheirPrefix() {
        let reply = """
        <SOAP-ENV:Body><tds:GetDeviceInformationResponse><tds:Manufacturer>Acme</tds:Manufacturer>\
        <tds:Model>Door 2</tds:Model><tds:FirmwareVersion> 1.2 </tds:FirmwareVersion><SerialNumber>XYZ</SerialNumber>\
        <tds:HardwareId></tds:HardwareId></tds:GetDeviceInformationResponse></SOAP-ENV:Body>
        """
        #expect(ONVIF.value(of: "Manufacturer", in: reply) == "Acme")
        #expect(ONVIF.value(of: "Model", in: reply) == "Door 2")
        #expect(ONVIF.value(of: "FirmwareVersion", in: reply) == "1.2")
        #expect(ONVIF.value(of: "SerialNumber", in: reply) == "XYZ")
        #expect(ONVIF.value(of: "HardwareId", in: reply) == nil)
    }

    @Test func usernamesAreEscaped() {
        #expect(ONVIF.escape("a<b>&c") == "a&lt;b&gt;&amp;c")
    }
}

struct FakeProvider: CameraProvider {
    let id: String
    var name: String { id }
    let answer: Config.Device?
    func identify(host: String, username: String, password: String) async -> Config.Device? { answer }
}

@Suite struct DeviceReaderTests {
    @Test func theFirstProviderThatAnswers() async {
        let acme = Config.Device(manufacturer: "Acme", model: "One", provider: "b")
        let device = await DeviceReader.read(host: "h", username: "u", password: "p", providers: [
            FakeProvider(id: "a", answer: nil), FakeProvider(id: "b", answer: acme),
            FakeProvider(id: "c", answer: Config.Device(manufacturer: "Other", model: "Two")),
        ])
        #expect(device == acme)
    }

    @Test func nobodyAnswers() async {
        #expect(await DeviceReader.read(host: "h", username: "u", password: "p", providers: [FakeProvider(id: "a", answer: nil)]) == nil)
    }

    @Test func providersByID() {
        #expect(CameraProviders.provider("reolink") is ReolinkProvider)
        #expect(CameraProviders.provider("onvif") is ONVIFProvider)
        #expect(CameraProviders.provider("nope") == nil)
    }
}

@Suite struct ProviderWordingTests {
    @Test func adviceNamesTheBrandOnlyWhenItsProviderIsKnown() {
        let reolink = Config.Device(manufacturer: "Reolink", model: "E1 Pro", provider: "reolink")
        #expect(reolink.appName == "the Reolink app")
        #expect(CameraProviders.provider(reolink.provider)?.subStreamName == "Fluent")
        let other = Config.Device(manufacturer: "Acme", model: "Cam", provider: "onvif")
        #expect(other.appName == "the camera\u{2019}s own app")
        #expect(CameraProviders.provider(other.provider)?.subStreamName == nil)
    }
}

@Suite struct ReolinkEventsTests {
    @Test func motionIsTheMotionAlarmOrAnyDetection() {
        #expect(ReolinkEvents.motion(in: ["md": ["alarm_state": 1]]))
        #expect(ReolinkEvents.motion(in: ["md": ["alarm_state": 0], "ai": ["people": ["alarm_state": 1, "support": 1]]]))
        #expect(!ReolinkEvents.motion(in: ["md": ["alarm_state": 0], "ai": ["people": ["alarm_state": 0]],
                                           "visitor": ["alarm_state": 1]]))
        #expect(!ReolinkEvents.motion(in: [:]))
    }
}

@Suite struct ProviderChoiceTests {
    static func device(_ maker: String, _ provider: String) -> Config.Device {
        Config.Device(manufacturer: maker, model: "M", serial: nil, firmware: nil, isDoorbell: false, provider: provider)
    }

    @Test func aReolinkCanUseItsOwnAPIOrONVIF() {
        #expect(CameraProviders.choices(for: Self.device("Reolink", "reolink")).map(\.id) == ["reolink", "onvif"])
        // Recognised over ONVIF (which spells the make its own way): its own API is still offered.
        #expect(CameraProviders.choices(for: Self.device("REOLINK", "onvif")).map(\.id) == ["reolink", "onvif"])
    }

    @Test func otherMakesHaveONVIFAndUnknownCamerasNothing() {
        #expect(CameraProviders.choices(for: Self.device("Hikvision", "onvif")).map(\.id) == ["onvif"])
        #expect(CameraProviders.choices(for: nil).isEmpty)
    }
}
