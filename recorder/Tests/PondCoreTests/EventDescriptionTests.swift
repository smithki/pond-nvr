import Testing
@testable import PondCore

@Suite struct EventDescriptionTests {
    @Test func sentencesThatSayNothing() {
        for sentence in ["Something.", "An object.", "A person.", "The image shows a scene.", "There is something in the picture.",
                         "Nothing visible.", ""] {
            #expect(EventDescription.saysNothing(sentence), "\(sentence)")
        }
    }

    @Test func sentencesThatSaySomething() {
        for sentence in ["A man in a grey hoodie walks up the driveway.", "A delivery driver leaves a box at the door.",
                         "A cat crosses the lawn at night.", "Two people talk by the gate."] {
            #expect(!EventDescription.saysNothing(sentence), "\(sentence)")
        }
    }
}
