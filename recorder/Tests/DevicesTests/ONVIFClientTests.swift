import Foundation
import Testing
@testable import Devices

/// ONVIF's replies, in the shapes cameras send (namespaces and prefixes vary from make to make).
@Suite struct ONVIFClientTests {
    static let profiles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
    <SOAP-ENV:Body><trt:GetProfilesResponse>
    <trt:Profiles token="000" fixed="true"><tt:Name>MainStream</tt:Name>
      <tt:VideoEncoderConfiguration token="000"><tt:Name>main</tt:Name><tt:Encoding>H264</tt:Encoding>
        <tt:Resolution><tt:Width>2560</tt:Width><tt:Height>1920</tt:Height></tt:Resolution>
        <tt:RateControl><tt:FrameRateLimit>20</tt:FrameRateLimit><tt:BitrateLimit>3072</tt:BitrateLimit></tt:RateControl>
      </tt:VideoEncoderConfiguration></trt:Profiles>
    <trt:Profiles token="001" fixed="true"><tt:Name>SubStream</tt:Name>
      <tt:VideoEncoderConfiguration token="001"><tt:Encoding>H264</tt:Encoding>
        <tt:Resolution><tt:Width>640</tt:Width><tt:Height>480</tt:Height></tt:Resolution>
        <tt:RateControl><tt:FrameRateLimit>15</tt:FrameRateLimit></tt:RateControl>
      </tt:VideoEncoderConfiguration></trt:Profiles>
    <trt:Profiles token="002"><tt:Name>Snapshot</tt:Name>
      <tt:VideoEncoderConfiguration token="002"><tt:Encoding>JPEG</tt:Encoding>
        <tt:Resolution><tt:Width>1280</tt:Width><tt:Height>960</tt:Height></tt:Resolution>
      </tt:VideoEncoderConfiguration></trt:Profiles>
    <trt:Profiles token="003"><tt:Name>Audio only</tt:Name></trt:Profiles>
    </trt:GetProfilesResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>
    """

    @Test func profilesAreReadWhateverTheirPrefixes() throws {
        let profiles = ONVIFClient.profiles(in: try XMLDocument(xmlString: Self.profiles))
        // The one without a video encoder is not a stream.
        #expect(profiles.map(\.token) == ["000", "001", "002"])
        #expect(profiles[0] == ONVIFClient.Profile(token: "000", name: "MainStream", encoding: "H264", width: 2560, height: 1920, fps: 20))
        #expect(profiles[2].fps == nil)
    }

    @Test func theMainStreamIsTheLargestH264AndTheSubTheSmallest() throws {
        let profiles = ONVIFClient.profiles(in: try XMLDocument(xmlString: Self.profiles))
        let chosen = try #require(ONVIFClient.choose(profiles))
        #expect(chosen.main.token == "000" && chosen.sub.token == "001")
        // JPEG never; one H.264 profile is both.
        let one = try #require(ONVIFClient.choose([profiles[0], profiles[2]]))
        #expect(one.main.token == "000" && one.sub.token == "000")
        #expect(ONVIFClient.choose([profiles[2]]) == nil)
    }

    @Test func streamAddressesLoseTheirLoginAndUseTheHostReached() {
        #expect(ONVIFClient.clean("rtsp://admin:secret@10.0.0.9:554/Preview_01_main", host: "192.168.1.30")
            == "rtsp://192.168.1.30:554/Preview_01_main")
        #expect(ONVIFClient.clean("rtsp://192.168.1.30/stream1?channel=1", host: "192.168.1.30") == "rtsp://192.168.1.30/stream1?channel=1")
        #expect(ONVIFClient.clean("http://192.168.1.30/mjpeg", host: "192.168.1.30") == nil)
    }

    @Test func theCameraClockFromItsTime() throws {
        let reply = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>
        <tds:GetSystemDateAndTimeResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><tds:SystemDateAndTime>
        <tt:UTCDateTime><tt:Time><tt:Hour>0</tt:Hour><tt:Minute>6</tt:Minute><tt:Second>24</tt:Second></tt:Time>
        <tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>16</tt:Day></tt:Date></tt:UTCDateTime>
        <tt:LocalDateTime><tt:Time><tt:Hour>18</tt:Hour><tt:Minute>6</tt:Minute><tt:Second>24</tt:Second></tt:Time>
        <tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>15</tt:Day></tt:Date></tt:LocalDateTime>
        </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse></s:Body></s:Envelope>
        """
        let time = try #require(ONVIF.cameraTime(in: reply))
        #expect(time == ISO8601DateFormatter().date(from: "2026-10-16T00:06:24Z"))
    }

    @Test func servicesReportedAtAnotherAddressAreReachedAtTheCamerasHost() {
        let client = ONVIFClient(host: "192.168.1.30", username: "u", password: "p",
                                 deviceService: URL(string: "http://192.168.1.30/onvif/device_service")!, clockOffset: 0)
        #expect(client.reachable("http://172.16.0.2:8000/onvif/Media2")?.absoluteString == "http://192.168.1.30:8000/onvif/Media2")
    }
}
