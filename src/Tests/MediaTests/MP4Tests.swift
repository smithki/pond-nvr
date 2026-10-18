import Testing
@testable import Media

@Suite struct MP4Tests {
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x33, 0xAC, 0x15, 0x14, 0xA0, 0x28, 0x00, 0xB5, 0x90]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0]
    static let video = VideoTrack(sps: sps, pps: pps, width: 2560, height: 1440)
    static let audio = AudioTrack(config: [0x14, 0x08], sampleRate: 16000, channels: 1)

    @Test func initSegmentDescribesBothTracks() throws {
        let boxes = Box.parse(MP4.initSegment(video: Self.video, audio: Self.audio))
        #expect(boxes.map(\.type) == ["ftyp", "moov"])
        let moov = boxes[1]
        let traks = moov.children.filter { $0.type == "trak" }
        #expect(traks.count == 2)
        #expect(moov.find("mvex")?.children.filter { $0.type == "trex" }.count == 2)

        let avc1 = try #require(traks[0].find("mdia", "minf", "stbl", "stsd", "avc1"))
        #expect(avc1.u32(24) == 2560 << 16 | 1440)   // width, height
        let avcC = try #require(Box.parse(Array(avc1.payload.dropFirst(78))).first)
        #expect(avcC.type == "avcC")
        #expect(Array(avcC.payload.prefix(4)) == [1, 0x64, 0x00, 0x33])
        #expect(Array(avcC.payload[8 ..< 8 + Self.sps.count]) == Self.sps)
        #expect(traks[0].find("mdia", "mdhd")?.u32(12) == 90000)

        let mp4a = try #require(traks[1].find("mdia", "minf", "stbl", "stsd", "mp4a"))
        #expect(mp4a.u32(24) == 16000 << 16)
        #expect(traks[1].find("mdia", "mdhd")?.u32(12) == 16000)
        // The AudioSpecificConfig sits in the esds' DecoderSpecificInfo (tag 5).
        let esds = try #require(Box.parse(Array(mp4a.payload.dropFirst(28))).first)
        #expect(esds.type == "esds")
        let tag5 = try #require(esds.payload.firstIndex(of: 0x05))
        #expect(Array(esds.payload[tag5 + 1 ... tag5 + 3]) == [2, 0x14, 0x08])
    }

    @Test func videoOnlyInitSegment() {
        let moov = Box.parse(MP4.initSegment(video: Self.video, audio: nil))[1]
        #expect(moov.children.filter { $0.type == "trak" }.count == 1)
    }

    @Test func fragmentOffsetsPointAtTheSamples() throws {
        let v1 = MP4Sample(data: [1, 1, 1], duration: 4500, isSync: true)
        let v2 = MP4Sample(data: [2, 2], duration: 4500, isSync: false)
        let a1 = MP4Sample(data: [9, 9, 9, 9], duration: 1024, isSync: true)
        let bytes = MP4.fragment(sequence: 7, video: [v1, v2], videoTime: 180_000, audio: [a1], audioTime: 32000)
        let boxes = Box.parse(bytes)
        #expect(boxes.map(\.type) == ["moof", "mdat"])
        let moof = boxes[0]
        #expect(moof.find("mfhd")?.u32(4) == 7)
        let trafs = moof.children.filter { $0.type == "traf" }
        #expect(trafs.count == 2)

        func check(_ traf: Box, track: UInt32, time: UInt64, samples: [MP4Sample]) {
            #expect(traf.find("tfhd")?.u32(4) == track)
            #expect(traf.find("tfdt")?.u64(4) == time)
            guard let trun = traf.find("trun") else { Issue.record("no trun"); return }
            #expect(trun.u32(4) == UInt32(samples.count))
            let offset = Int(trun.u32(8))
            var at = moof.start + offset
            for (n, s) in samples.enumerated() {
                #expect(trun.u32(12 + 12 * n) == s.duration)
                #expect(trun.u32(16 + 12 * n) == UInt32(s.data.count))
                #expect(trun.u32(20 + 12 * n) == (s.isSync ? 0x0200_0000 : 0x0101_0000))
                #expect(Array(bytes[at ..< at + s.data.count]) == s.data)
                at += s.data.count
            }
        }
        check(trafs[0], track: 1, time: 180_000, samples: [v1, v2])
        check(trafs[1], track: 2, time: 32000, samples: [a1])
    }

    @Test func avccLengthPrefixes() {
        #expect(MP4.avcc([[0x65, 1, 2], [0x06]]) == [0, 0, 0, 3, 0x65, 1, 2, 0, 0, 0, 1, 0x06])
    }
}

@Suite struct FragmentWriterTests {
    /// 20 fps for `frames` frames, keyframe every 40; audio every 1024 samples at 16 kHz.
    static func feed(_ w: FragmentWriter, frames: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var audioNext: Int64 = 0
        for f in 0 ..< frames {
            let time = Int64(f) * 4500
            while audioNext * 90000 / 16000 <= time {
                w.addAudio(time: audioNext, data: [0xA])
                audioNext += 1024
            }
            if let fragment = w.addVideo(time: time, nalus: [[f % 40 == 0 ? 0x65 : 0x41, UInt8(f & 0xFF)]], isKeyframe: f % 40 == 0) {
                out.append(fragment)
            }
        }
        return out
    }

    @Test func fragmentsStartAtKeyframesAndCarryTheirAudio() throws {
        let w = FragmentWriter(video: MP4Tests.video, audio: MP4Tests.audio, fragmentSeconds: 2)
        let fragments = Self.feed(w, frames: 200)   // 10 s
        #expect(fragments.count == 4)                // cut at 2, 4, 6, 8 s; 8-10 s still held
        let last = try #require(w.finish())
        #expect(w.videoFrames == 200)
        #expect(abs(w.writtenSeconds - 10) < 0.001)

        for (n, fragment) in (fragments + [last]).enumerated() {
            let moof = Box.parse(fragment)[0]
            let trafs = moof.children.filter { $0.type == "traf" }
            let videoTrun = try #require(trafs[0].find("trun"))
            #expect(videoTrun.u32(4) == 40)
            #expect(videoTrun.u32(20) == 0x0200_0000)              // first sample is a keyframe
            #expect(trafs[0].find("tfdt")?.u64(4) == UInt64(n) * 180_000)
            // Audio covering the same 2 s: about 31 frames of 1024 samples.
            let audioTrun = try #require(trafs[1].find("trun"))
            #expect((31 ... 32).contains(audioTrun.u32(4)))
        }
        #expect(w.audioFrames >= 155)
    }

    @Test func aacFramesLastTheir1024SamplesWhenTheyArriveInBursts() throws {
        // Sound timed in bursts, as a doorbell sends it (frames 54 samples apart, then a pause): each frame still
        // lasts 1024, one after another; a real gap (here 5 frames' worth) is kept.
        let w = FragmentWriter(video: MP4Tests.video, audio: MP4Tests.audio, fragmentSeconds: 2)
        var time: Int64 = 0
        for n in 0 ..< 30 {
            w.addAudio(time: time, data: [0x21])
            // Three frames 54 apart, then a pause: four frames over 4096 samples, as real time has it.
            time += n % 4 == 3 ? 4 * 1024 - 54 * 3 : 54
            if n == 20 { time += 5 * 1024 }
        }
        _ = w.addVideo(time: 0, nalus: [[0x65]], isKeyframe: true)
        _ = w.addVideo(time: 3000, nalus: [[0x41]], isKeyframe: false)
        let fragment = try #require(w.finish(until: 360_000))
        let audio = try #require(Box.parse(fragment)[0].children.filter { $0.type == "traf" }[1].find("trun"))
        let flags = audio.u32(0) & 0xFF_FFFF
        let fields = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count
        var at = 8 + (flags & 0x1 != 0 ? 4 : 0) + (flags & 0x4 != 0 ? 4 : 0)
        var durations: [UInt32] = []
        for _ in 0 ..< audio.u32(4) {
            durations.append(audio.u32(at))
            at += 4 * fields
        }
        #expect(durations.count == 30)
        #expect(durations.filter { $0 == 1024 }.count == 29)
        #expect(durations.contains { $0 > 5 * 1024 })
    }

    @Test func framesBeforeTheFirstKeyframeAreDropped() {
        let w = FragmentWriter(video: MP4Tests.video, audio: nil)
        #expect(w.addVideo(time: 0, nalus: [[0x41]], isKeyframe: false) == nil)
        #expect(w.finish() == nil)
        _ = w.addVideo(time: 4500, nalus: [[0x65]], isKeyframe: true)
        _ = w.addVideo(time: 4500, nalus: [[0x41]], isKeyframe: false)   // repeated time: dropped
        _ = w.addVideo(time: 9000, nalus: [[0x41]], isKeyframe: false)
        #expect(w.finish() != nil)
        #expect(w.videoFrames == 2)
    }
}
