// Whether a sentence from the language model says anything about an event's picture. Now and then it answers with
// nothing ("Something.", "An object.", "The image shows a scene."); such an answer is no description at all, and the
// event is said from what was detected instead ("A person, in Garage."), which is better than it.
import Foundation

public enum EventDescription {
    /// Words that carry nothing about what's in the picture.
    static let empty: Set<String> = [
        "a", "an", "the", "this", "that", "it", "is", "are", "of", "in", "there", "shows", "showing", "depicts", "appears",
        "to", "be", "some", "something", "someone", "object", "objects", "thing", "things", "image", "picture", "photo",
        "scene", "view", "unclear", "unknown", "nothing", "blurry", "visible",
    ]

    /// Fewer than three words, or only words that say nothing.
    public static func saysNothing(_ sentence: String) -> Bool {
        let words = sentence.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        return words.count < 3 || words.allSatisfy { empty.contains($0) }
    }
}
