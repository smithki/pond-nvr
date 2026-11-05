import AVFoundation
import CoreGraphics
import Detection
import ImageIO
import Foundation
import HAPCamera
import Ingest
import PondCore
import Testing
@testable import Demo
import Recorder

@Suite(.serialized) struct DemoTests {
    let world = DemoWorld(scenario: .home, folder: nil)

    @Test func theScriptIsTheSameEveryTime() {
        let camera = Demo.Scenario.home.cameras[1]
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let a = DemoScript.visits(scenario: "home", camera: camera, busyness: 6, around: t)
        let b = DemoScript.visits(scenario: "home", camera: camera, busyness: 6, around: t)
        #expect(a.map(\.start) == b.map(\.start))
        #expect(a.map(\.visitor) == b.map(\.visitor))
    }

    @Test func aBusyDayHasVisitsOfManyKinds() {
        let camera = Demo.Scenario.home.cameras[1]   // the driveway: cars, people, couriers
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let visits = (0 ..< 144).flatMap {
            DemoScript.visits(scenario: "home", camera: camera.id, scene: camera.scene, busyness: 6,
                              block: Int64(day.timeIntervalSince1970 / DemoScript.block) + Int64($0))
        }
        #expect(visits.count > 40)
        #expect(Set(visits.map(\.visitor)).isSuperset(of: [.car, .person]))
    }

    @Test func whatsFoundIsWhereItsDrawnAndInTheFrame() {
        let camera = Demo.Scenario.home.cameras[0]
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        var found = 0
        for second in stride(from: 0, to: 86400, by: 15) {
            for d in world.detections(camera.id, at: day.addingTimeInterval(Double(second))) {
                found += 1
                #expect(d.box.x >= 0 && d.box.y >= 0 && d.box.x + d.box.width <= 1.0001 && d.box.y + d.box.height <= 1.0001)
            }
        }
        #expect(found > 50)
    }

    @Test func zoomingInShowsLessOfTheSceneAndBiggerFigures() {
        let id = "backyard"
        let before = world.view(id)
        world.change(id) { $0.zoom = 2 }
        let after = world.view(id)
        #expect(after.width == before.width / 2)
        world.home(id)
    }

    @Test func aStreamIsH264ThatDecodesFromItsFirstPacket() throws {
        let stream = try DemoStream(url: "demo://driveway.home/sub", world: world)
        defer { stream.close() }
        #expect(stream.video.encoding == "H264")
        #expect(stream.video.format["sprop-parameter-sets"]?.contains(",") == true)
        var depacketizer = H264Depacketizer(spropParameterSets: stream.video.format["sprop-parameter-sets"])
        var units: [H264AccessUnit] = []
        var reports = 0
        let started = Date()
        while units.count < 12, Date().timeIntervalSince(started) < 5 {
            guard let packet = try stream.next(timeout: 1) else { continue }
            if packet.channel == 1 { reports += 1; continue }
            if let rtp = RTPPacket(packet.data) { units += depacketizer.push(rtp) }
        }
        #expect(units.count >= 10)
        #expect(units.first?.isKeyframe == true)
        #expect(reports >= 1)
        // Ten pictures a second, more or less.
        #expect(Date().timeIntervalSince(started) > 0.8)
    }

    @Test func anH265CameraSendsH265() throws {
        let stream = try DemoStream(url: "demo://side-gate.home/sub", world: world)
        defer { stream.close() }
        #expect(stream.video.encoding == "H265")
        #expect(stream.video.format["sprop-vps"] != nil && stream.video.format["sprop-pps"] != nil)
        var depacketizer = VideoDepacketizer(video: stream.video)
        #expect(depacketizer.codec == .h265 && depacketizer.parameterSets != nil)
        var units: [VideoAccessUnit] = []
        let started = Date()
        while units.count < 5, Date().timeIntervalSince(started) < 5 {
            guard let packet = try stream.next(timeout: 1), packet.channel == 0, let rtp = RTPPacket(packet.data) else { continue }
            units += depacketizer.push(rtp)
        }
        #expect(units.count >= 5)
        #expect(units.first?.isKeyframe == true)
        #expect(depacketizer.parameterSets?.size?.width == 640)
    }

    @Test func anH265CameraIsRecordedAsHvc1ThatAVFoundationPlays() async throws {
        let stream = try DemoStream(url: "demo://side-gate.home/sub", world: world)
        defer { stream.close() }
        let recorder = StreamRecorder(video: stream.video, audio: nil)
        var bytes: [UInt8] = []
        let started = Date()
        while Date().timeIntervalSince(started) < 4.5 {
            guard let packet = try stream.next(timeout: 1) else { continue }
            for output in recorder.handle(packet, now: Date().timeIntervalSince1970) {
                switch output {
                case let .start(initSegment, _): bytes += initSegment
                case let .fragment(f): bytes += f
                case .end: break
                }
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("h265-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(bytes).write(to: file)
        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(try await track.load(.naturalSize) == CGSize(width: 640, height: 360))
        #expect(try await asset.load(.duration).seconds > 2)
    }

    @Test func anAddressFromAnotherScenarioIsntOpened() {
        #expect(throws: RTSPError.self) { try DemoStream(url: "demo://driveway.trouble/sub", world: world) }
    }

    @Test func aStreamCarriesSoundAsAACAlongsideItsPictures() throws {
        let stream = try DemoStream(url: "demo://driveway.home/sub", world: world)
        defer { stream.close() }
        #expect(stream.audio?.encoding.uppercased() == "MPEG4-GENERIC")
        #expect(stream.audio?.format["config"] == DemoSound.config)
        var sound = 0, bytes = 0
        let started = Date()
        while sound < 8, Date().timeIntervalSince(started) < 3 {
            guard let packet = try stream.next(timeout: 1), packet.channel == CameraSession.audioChannel,
                  let rtp = RTPPacket(packet.data) else { continue }
            let frames = RTPPacketizer.aacFrames(inPayload: rtp.payload)
            sound += frames.count
            bytes += frames.reduce(0) { $0 + $1.count }
        }
        #expect(sound >= 8)
        #expect(bytes > 0)
    }

    @Test func thePastIsDrawnFasterThanRealTime() throws {
        let to = Date(timeIntervalSince1970: 1_790_000_000), from = to.addingTimeInterval(-60)
        let stream = try DemoStream(url: "demo://driveway.home/main", world: world, replaying: from, to: to, fps: 5)
        defer { stream.close() }
        #expect(stream.audio == nil)
        var depacketizer = H264Depacketizer(spropParameterSets: stream.video.format["sprop-parameter-sets"])
        var units = 0
        let started = Date()
        while true {
            let packet: InterleavedPacket?
            do { packet = try stream.next(timeout: 1) } catch { break }
            guard let packet, packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            units += depacketizer.push(rtp).count
        }
        // A minute at five a second, in well under the minute.
        #expect(units >= 295)
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test func aScenarioIsPreparedInItsOwnFolderAndKeptAfter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try Demo.prepare(.home, at: folder, fresh: false)
        let config = try ConfigStore(path: folder + "/config.json").load()
        #expect(config.cameras.count == 6)
        #expect(config.cameras.allSatisfy { $0.main.hasPrefix("demo://") && $0.device?.provider == "demo" })
        #expect(config.storage.recordingsPath.hasPrefix(folder))
        #expect(Demo.scenario(nextTo: folder + "/config.json")?.name == "home")
        #expect(PrivacyState(path: PrivacyState.path(nextTo: folder + "/config.json")).isPrivate("living-room"))
    }
}

/// Every scene painted, by day and by night: with POND_DEMO_PICTURES=<folder>, saved there to look at.
@Suite struct DemoPictureTests {
    @Test func everySceneIsPainted() throws {
        let scenario = Demo.Scenario(name: "pictures", title: "", about: "", pondName: "",
                                     cameras: Demo.Scene.allCases.map { .init($0.rawValue, $0.rawValue, scene: $0, doorbell: $0 == .frontDoor) },
                                     busyness: 30)
        let world = DemoWorld(scenario: scenario, folder: nil)
        let folder = ProcessInfo.processInfo.environment["POND_DEMO_PICTURES"]
        var calendar = Calendar.current
        calendar.timeZone = .current
        let noon = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        for camera in scenario.cameras {
            for (name, t) in [("day", noon), ("night", noon.addingTimeInterval(10 * 3600))] {
                // A moment with someone in it, if the hour has one.
                let busy = stride(from: 0.0, to: 3600, by: 5).map { t.addingTimeInterval($0) }
                    .first { !world.figures(camera.id, at: $0).isEmpty } ?? t
                let painter = DemoPainter(camera: camera, world: world, width: 960, height: camera.doorbell ? 720 : 540)
                let context = try #require(CGContext(data: nil, width: painter.width, height: painter.height, bitsPerComponent: 8,
                                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
                painter.paint(context, at: busy)
                let image = try #require(context.makeImage())
                if let folder {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(camera.id)-\(name).png") as CFURL
                    let destination = try #require(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
        }
    }
}
