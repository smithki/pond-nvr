import Testing
@testable import Ingest

@Suite struct StreamFormatTests {
    @Test func reolinkSDP() throws {
        let sdp = SDP(Fixtures.mainSDP)
        let video = try #require(sdp.video)
        #expect(video.encoding == "H264")
        #expect(video.clockRate == 90000)
        #expect(video.payloadType == 96)
        #expect(video.control == "track1")
        #expect(video.format["packetization-mode"] == "1")
        let audio = try #require(sdp.audio)
        #expect(audio.encoding == "MPEG4-GENERIC")
        #expect(audio.clockRate == 16000)
        #expect(audio.format["config"] == "1408")
        #expect(SDP.trackURL(base: "rtsp://h:554/main", control: "track1") == "rtsp://h:554/main/track1")
        #expect(SDP.trackURL(base: "rtsp://h:554/main", control: "rtsp://h:554/main/trackID=0") == "rtsp://h:554/main/trackID=0")
        #expect(SDP.trackURL(base: "rtsp://h:554/main", control: "*") == "rtsp://h:554/main")
    }

    // ffprobe read these streams as 2560x1440 and 896x512, High, level 5.1.
    @Test func reolinkSPS() throws {
        let main = try #require(H264SPS(spropParameterSets: "Z2QAM6wVFKAoALWQ,aO48sA=="))
        #expect(main == H264SPS(profileIDC: 100, levelIDC: 51, width: 2560, height: 1440))
        #expect(main.profileName == "High")
        #expect(main.levelName == "5.1")
        let sub = try #require(H264SPS(spropParameterSets: "Z2QAM6wVFKDgEGQ=,aO48sA=="))
        #expect(sub.width == 896)
        #expect(sub.height == 512)
    }

    // A common 1080p SPS: 1088 lines coded, cropped to 1080.
    @Test func croppedSPS() throws {
        let sps = try #require(H264SPS(spropParameterSets: "Z2QAKKwbGoB4AiflwFuAgICgAAADACAAAAZR4wZU,aO48MA=="))
        #expect(sps.width == 1920)
        #expect(sps.height == 1080)
    }

    @Test func notAnSPS() {
        #expect(H264SPS(spropParameterSets: "aO48sA==") == nil)
        #expect(H264SPS(spropParameterSets: "!!!") == nil)
    }

    @Test func aacConfig() throws {
        let aac = try #require(AACConfig(hex: "1408"))
        #expect(aac == AACConfig(objectType: 2, sampleRate: 16000, channels: 1))
        #expect(aac.profileName == "AAC-LC")
        #expect(AACConfig(hex: "1210")?.sampleRate == 44100)
        #expect(AACConfig(hex: "12")  == nil)
    }

    @Test func streamInfo() {
        let info = StreamInfo(SDP(Fixtures.mainSDP))
        #expect(info.videoCodec == "H.264")
        #expect(info.sps?.width == 2560)
        #expect(info.audio?.sampleRate == 16000)
    }
}
