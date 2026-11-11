import Foundation
import Network
import Testing
@testable import HAP

@Suite struct DataStreamTests {
    let secret = [UInt8](repeating: 0x11, count: 32)
    let controllerSalt = [UInt8](repeating: 0x22, count: 32)
    let accessorySalt = [UInt8](repeating: 0x33, count: 32)

    @Test func eachDirectionHasItsOwnKey() {
        let keys = DataStream.Keys(sharedSecret: secret, controllerSalt: controllerSalt, accessorySalt: accessorySalt)
        #expect(keys.read.count == 32 && keys.write.count == 32 && keys.read != keys.write)
        // The salt is the controller's then the accessory's: swapped, the keys differ.
        #expect(DataStream.Keys(sharedSecret: secret, controllerSalt: accessorySalt, accessorySalt: controllerSalt) != keys)
    }

    @Test func framesSealAndOpenInOrder() throws {
        let key = [UInt8](repeating: 5, count: 32)
        var out = DataStream.Cipher(key: key), into = DataStream.Cipher(key: key)
        var reader = DataStream.FrameReader()
        let bytes = out.seal([1, 2, 3]) + out.seal([4, 5])
        #expect(Array(bytes.prefix(4)) == [1, 0, 0, 3])                         // type 1, 24-bit length
        // Split anywhere, they come out whole.
        let frames = try reader.push(Array(bytes.prefix(10))) + reader.push(Array(bytes.dropFirst(10)))
        #expect(frames.count == 2)
        #expect(into.open(header: frames[0].header, sealed: frames[0].sealed, tag: frames[0].tag) == [1, 2, 3])
        #expect(into.open(header: frames[1].header, sealed: frames[1].sealed, tag: frames[1].tag) == [4, 5])
        var wrong = DataStream.Cipher(key: [UInt8](repeating: 6, count: 32))
        #expect(wrong.open(header: frames[0].header, sealed: frames[0].sealed, tag: frames[0].tag) == nil)
    }

    @Test func messagesRoundTrip() throws {
        let hello = DataStream.Message(kind: .request, protocol: "control", topic: "hello", id: 1)
        let back = try DataStream.Message(payload: hello.payload)
        #expect(back == hello)
        let response = back.response()
        #expect(response.kind == .response && response.id == 1 && response.status == 0)
        #expect(try DataStream.Message(payload: response.payload) == response)
    }

    @Test func badSetupsAreRefused() {
        let server = DataStreamServer()
        // A short salt, another transport, or no session: generic error.
        let short = TLV8.encode([TLV8Item(0x01, [0]), TLV8Item(0x02, [0]), TLV8Item(0x03, [1, 2])])
        #expect(server.setup(short, sharedSecret: secret) == TLV8.encode([TLV8Item(0x01, [1])]))
        let good = TLV8.encode([TLV8Item(0x01, [0]), TLV8Item(0x02, [0]), TLV8Item(0x03, controllerSalt)])
        #expect(server.setup(good, sharedSecret: nil) == TLV8.encode([TLV8Item(0x01, [1])]))
        server.stop()
    }

    /// A controller sets up a stream, connects, says hello and gets the answer, over a real local socket.
    @Test func aControllerConnectsAndIsGreeted() async throws {
        let server = DataStreamServer()
        defer { server.stop() }
        let request = TLV8.encode([TLV8Item(0x01, [0]), TLV8Item(0x02, [0]), TLV8Item(0x03, controllerSalt)])
        let reply = try TLV8.decode(server.setup(request, sharedSecret: secret))
        #expect(reply.value(0x01) == [0])
        let params = try TLV8.decode(try #require(reply.value(0x02)))
        let portBytes = try #require(params.value(0x01))
        let port = UInt16(portBytes[0]) | UInt16(portBytes[1]) << 8
        let theirSalt = try #require(reply.value(0x03))
        let keys = DataStream.Keys(sharedSecret: secret, controllerSalt: controllerSalt, accessorySalt: theirSalt)

        // The controller writes with the write key and reads with the read key.
        var toAccessory = DataStream.Cipher(key: keys.write)
        var fromAccessory = DataStream.Cipher(key: keys.read)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "test"))
        let hello = DataStream.Message(kind: .request, protocol: "control", topic: "hello", id: 7)
        connection.send(content: Data(toAccessory.seal(hello.payload)), completion: .idempotent)
        let data: Data = try await withCheckedThrowingContinuation { done in
            connection.receive(minimumIncompleteLength: 4 + 16, maximumLength: 4096) { data, _, _, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CancellationError()) }
            }
        }
        connection.cancel()
        var reader = DataStream.FrameReader()
        let frames = try reader.push([UInt8](data))
        let frame = try #require(frames.first)
        let opened = fromAccessory.open(header: frame.header, sealed: frame.sealed, tag: frame.tag)
        let payload = try #require(opened)
        let answer = try DataStream.Message(payload: payload)
        #expect(answer.kind == .response && answer.topic == "hello" && answer.id == 7 && answer.status == 0)
    }
}
