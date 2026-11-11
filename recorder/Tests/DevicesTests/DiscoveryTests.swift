import Foundation
import Testing
@testable import Devices

/// What cameras send back to an ONVIF discovery probe (WS-Discovery ProbeMatches), and the probe itself.
@Suite struct DiscoveryTests {
    static let probeMatches = """
    <?xml version="1.0" encoding="UTF-8"?>
    <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
    <SOAP-ENV:Header><wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action></SOAP-ENV:Header>
    <SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch>
    <wsa:EndpointReference><wsa:Address>urn:uuid:2419d68a-2dd2-21b2-a205-ec2f00000001</wsa:Address></wsa:EndpointReference>
    <d:Types>dn:NetworkVideoTransmitter</d:Types>
    <d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Garden%20Camera onvif://www.onvif.org/hardware/DS-2CD2143G2-I onvif://www.onvif.org/location/country/</d:Scopes>
    <d:XAddrs>http://192.168.1.30/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs>
    <d:MetadataVersion>1</d:MetadataVersion>
    </d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>
    """

    @Test func aCameraFromItsAnswer() throws {
        let camera = try #require(ONVIFDiscovery.matches(in: Self.probeMatches).first)
        #expect(camera.id == "urn:uuid:2419d68a-2dd2-21b2-a205-ec2f00000001")
        #expect(camera.host == "192.168.1.30")
        #expect(camera.name == "Garden Camera" && camera.hardware == "DS-2CD2143G2-I")
        #expect(camera.addresses.count == 2)
        #expect(camera.title == "Garden Camera")
    }

    @Test func notAnAnswerIsNothing() {
        #expect(ONVIFDiscovery.matches(in: "not xml").isEmpty)
        #expect(ONVIFDiscovery.matches(in: "<a><ProbeMatch><Scopes/></ProbeMatch></a>").isEmpty)   // no address
    }

    @Test func theProbeAsksForCamerasOrAnything() {
        #expect(ONVIFDiscovery.probeMessage().contains("<d:Types>dn:NetworkVideoTransmitter</d:Types>"))
        #expect(!ONVIFDiscovery.probeMessage(anyDevice: true).contains("<d:Types>"))
    }

    @Test func addressesAreWrittenOut() {
        #expect(NetworkScan.text(0xC0A8_0114) == "192.168.1.20")
    }

    /// A Reolink camera's answer to its discovery broadcast: 388 bytes, its fields at fixed places.
    static func reolinkAnswer(host: String, name: String, mac: String) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 388)
        func put(_ text: String, at offset: Int) { for (i, b) in text.utf8.enumerated() { data[offset + i] = b } }
        data.replaceSubrange(104 ..< 108, with: [0xAA, 0xAA, 0x00, 0x00])
        put(host, at: 108)
        put(name, at: 132)
        put(mac, at: 164)
        put("95270000ABCDEF", at: 228)
        return data
    }

    @Test func aReolinkAnswerIsRead() throws {
        let camera = try #require(ReolinkDiscovery.answer(Self.reolinkAnswer(host: "192.168.1.31", name: "Garage Camera", mac: "EC:71:DB:00:00:01")))
        #expect(camera == ReolinkFound(host: "192.168.1.31", name: "Garage Camera", mac: "EC:71:DB:00:00:01", uuid: "95270000ABCDEF"))
        // Our own ask echoing back, or something else's packet: not answers.
        #expect(ReolinkDiscovery.answer([0xAA, 0xAA, 0x00, 0x00]) == nil)
        var wrong = Self.reolinkAnswer(host: "192.168.1.31", name: "X", mac: "M")
        wrong[105] = 0
        #expect(ReolinkDiscovery.answer(wrong) == nil)
    }
}
