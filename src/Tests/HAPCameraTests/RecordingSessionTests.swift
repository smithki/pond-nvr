import Foundation
@testable import HAP
import Network
import Testing
@testable import HAPCamera

/// The whole path a clip takes, with this test as the home hub: a data stream set up and greeted, a recording
/// asked for, and the camera's prebuffered and live frames coming back as fragmented MP4 in dataSend events.
@Suite struct RecordingSessionTests {
    /// The hub's choice for the test clip: 160×120 at 10 fps, a keyframe and a fragment every 2 s.
    static var choice: [UInt8] {
        func le32(_ v: Int) -> [UInt8] { RecordingOptions.le32(UInt32(v)) }
        let recording = CameraTLV.item(0x01, le32(4000)) + CameraTLV.item(0x02, le32(1) + [0, 0, 0, 0])
            + CameraTLV.item(0x03, CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, CameraTLV.item(0x01, le32(2000))))
        let video = CameraTLV.item(0x01, 0)
            + CameraTLV.item(0x02, CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0) + CameraTLV.item(0x03, le32(300))
                + CameraTLV.item(0x04, le32(2000)))
            + CameraTLV.item(0x03, CameraTLV.item(0x01, CameraTLV.uint16(160)) + CameraTLV.item(0x02, CameraTLV.uint16(120))
                + CameraTLV.item(0x03, 10))
        let audio = CameraTLV.item(0x01, 0) + CameraTLV.item(0x02, CameraTLV.item(0x01, 1) + CameraTLV.item(0x02, 0)
            + CameraTLV.item(0x03, 1) + CameraTLV.item(0x04, le32(32)))
        return CameraTLV.item(0x01, recording) + CameraTLV.item(0x02, video) + CameraTLV.item(0x03, audio)
    }

    /// The hub's side of a data stream: its keys and frames.
    final class Hub: @unchecked Sendable {
        var out: DataStream.Cipher
        var into: DataStream.Cipher
        var reader = DataStream.FrameReader()
        let connection: NWConnection

        init(port: UInt16, keys: DataStream.Keys) {
            out = DataStream.Cipher(key: keys.write)
            into = DataStream.Cipher(key: keys.read)
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: DispatchQueue(label: "hub"))
        }

        func send(_ message: DataStream.Message) {
            connection.send(content: Data(out.seal(message.payload)), completion: .idempotent)
        }

        /// Messages until `done` says enough, or `seconds` pass.
        func receive(for seconds: Double, until done: ([DataStream.Message]) -> Bool) async throws -> [DataStream.Message] {
            var messages: [DataStream.Message] = []
            let deadline = Date().addingTimeInterval(seconds)
            // A read waits for data: past the deadline, the connection is cancelled, which ends it.
            let connection = self.connection
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { connection.cancel() }
            while Date() < deadline, !done(messages) {
                let data: Data? = await withCheckedContinuation { next in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                        next.resume(returning: error == nil ? data : nil)
                    }
                }
                guard let data else { break }
                for frame in try reader.push([UInt8](data)) {
                    guard let payload = into.open(header: frame.header, sealed: frame.sealed, tag: frame.tag) else { continue }
                    messages.append(try DataStream.Message(payload: payload))
                }
            }
            return messages
        }
    }

    @Test func aRecordingComesBackAsFragmentedMP4() async throws {
        let (sps, pps, units) = try VideoTranscoderTests.frames()
        let prebuffer = Prebuffer(source: ("rtsp://test", "u", "p"), seconds: 10) { _ in }
        func feed(_ i: Int) {
            let keyframe = units[i].nalus.first.map { $0[0] & 0x1F == 5 } ?? false
            prebuffer.keep(.video(.init(nalus: units[i].nalus, keyframe: keyframe, sps: sps, pps: pps,
                                        time: units[i].time, wall: 1000 + Double(i) / 10)))
        }
        for i in 0 ..< 30 { feed(i) }   // 3 s kept before the hub asks

        var state = RecordingState()
        state.active = true
        state.selected = Self.choice
        state.offered = RecordingOptions(doorbell: false).digest   // chosen among what is offered now
        let controller = RecordingController(options: RecordingOptions(doorbell: false), state: state, prebuffer: prebuffer) { _ in }
        defer { controller.stop() }

        let salt = [UInt8](repeating: 0x22, count: 32), secret = [UInt8](repeating: 0x11, count: 32)
        let reply = try TLV8.decode(controller.dataStream.setup(
            TLV8.encode([TLV8Item(0x01, [0]), TLV8Item(0x02, [0]), TLV8Item(0x03, salt)]), sharedSecret: secret))
        let parameters = try #require(reply.value(0x02))
        let portBytes = try #require(try TLV8.decode(parameters).value(0x01))
        let accessorySalt = try #require(reply.value(0x03))
        let keys = DataStream.Keys(sharedSecret: secret, controllerSalt: salt, accessorySalt: accessorySalt)
        let hub = Hub(port: UInt16(portBytes[0]) | UInt16(portBytes[1]) << 8, keys: keys)
        defer { hub.connection.cancel() }

        hub.send(DataStream.Message(kind: .request, protocol: "control", topic: "hello", id: 1))
        hub.send(DataStream.Message(kind: .request, protocol: "dataSend", topic: "open", id: 2, body: .dictionary([
            ("target", .string("controller")), ("type", .string("ipcamera.recording")),
            ("streamId", .int(1)), ("reason", .string("motion")),
        ])))
        try await Task.sleep(for: .milliseconds(300))
        for i in 30 ..< 50 { feed(i) }   // the rest, live

        let messages = try await hub.receive(for: 10) { got in
            got.filter { $0.topic == "data" }.count >= 2
        }
        let opened = try #require(messages.first { $0.topic == "open" })
        #expect(opened.kind == .response && opened.status == 0 && opened.body["status"]?.int == 0)

        let data = messages.filter { $0.kind == .event && $0.protocol == "dataSend" && $0.topic == "data" }
        // The initialization segment and the first fragment (the next ends at a keyframe the clip runs out
        // before; a camera's stream always has one).
        try #require(data.count >= 2)
        struct Missing: Error {}
        func packet(_ m: DataStream.Message) throws -> (bytes: [UInt8], meta: Opack) {
            guard let p = m.body["packets"]?.array?.first, let bytes = p["data"]?.data, let meta = p["metadata"] else {
                throw Missing()
            }
            return (bytes, meta)
        }
        let initialization = try packet(data[0])
        #expect(data[0].body["streamId"]?.int == 1)
        #expect(initialization.meta["dataType"]?.string == "mediaInitialization")
        #expect(initialization.meta["dataSequenceNumber"]?.int == 1)
        #expect(initialization.meta["isLastDataChunk"]?.bool == true)
        #expect(initialization.meta["dataTotalSize"]?.int == Int64(initialization.bytes.count))
        #expect(String(decoding: initialization.bytes[4 ..< 8], as: UTF8.self) == "ftyp")
        let fragment = try packet(data[1])
        #expect(fragment.meta["dataType"]?.string == "mediaFragment")
        #expect(fragment.meta["dataSequenceNumber"]?.int == 2)
        #expect(String(decoding: fragment.bytes[4 ..< 8], as: UTF8.self) == "moof")
    }
}
