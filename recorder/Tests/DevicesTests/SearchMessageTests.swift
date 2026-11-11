import Foundation
import Testing
import Understanding
@testable import Devices

/// Search over the control socket: a question, and how it was read, there and back as JSON lines.
@Suite struct SearchMessageTests {
    @Test func aQuestionAndItsAnswerGoThereAndBack() throws {
        var request = ControlSocket.Request(camera: "", action: "search")
        request.question = "a dog on the couch last night"
        let night = Date(timeIntervalSince1970: 1_800_000_000) ... Date(timeIntervalSince1970: 1_800_036_000)
        let query = EventQuery(kinds: ["animal"], things: ["dog"], cameras: ["Living Room"],
                               time: TimeFilter(range: night, hours: .init(from: 20, to: 6)), appearance: "a dog on the couch")
        request.reading = query
        request.byModel = true
        let line = ControlSocket.line(request)
        #expect(line.last == 0x0A)
        let back = try JSONDecoder().decode(ControlSocket.Request.self, from: Data(line.dropLast()))
        #expect(back.question == request.question && back.reading == query && back.byModel == true)

        let reply = ControlSocket.Reply()
        var answered = reply
        answered.search = SearchResult(question: "a dog on the couch last night", query: query, byModel: true, ids: ["e2", "e1"],
                                       ranked: true, appearanceIgnored: false)
        let replyBack = try JSONDecoder().decode(ControlSocket.Reply.self, from: Data(ControlSocket.line(answered).dropLast()))
        #expect(replyBack.search == answered.search)
    }

    /// A request from before search (no search fields) still reads.
    @Test func anOlderRequestStillReads() throws {
        let old = try JSONDecoder().decode(ControlSocket.Request.self, from: Data(#"{"camera":"porch","action":"controls"}"#.utf8))
        #expect(old.action == "controls" && old.question == nil && old.reading == nil)
    }
}
