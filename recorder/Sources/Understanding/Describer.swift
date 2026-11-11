// A sentence an event: what the picture shows, in words a search can find later (who or what, doing what, and the
// details that tell one from another: clothes and their colours, a vehicle's kind and colour, what's carried). By
// the Mac's own language model (Foundation Models, which takes pictures from macOS 27), on the Mac only: never
// Private Cloud Compute. Without Apple Intelligence (off, its model still downloading, or a Mac that can't run it)
// there are no sentences; everything else works, and events show what was found instead.
import CoreGraphics
import Foundation
import PondCore
import FoundationModels

public struct Describer: Sendable {
    /// Whether sentences can be written now, and if not, why.
    public enum Availability: Equatable, Sendable {
        case available
        /// Apple Intelligence is off (System Settings › Apple Intelligence & Siri).
        case turnedOff
        /// Its model is still being made ready (downloading).
        case notReady
        /// This Mac can't run it.
        case notEligible
        case unavailable(String)
    }

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .turnedOff
        case .unavailable(.modelNotReady): .notReady
        case .unavailable(.deviceNotEligible): .notEligible
        case let .unavailable(other): .unavailable(String(describing: other))
        }
    }

    /// What it's told before every picture.
    static let instructions = """
    You describe pictures from a home security camera, one short sentence each, for a log that will be searched later.
    Say who or what is there and what they are doing, with the details that would help find this moment again: \
    clothing and its colours, a vehicle's kind and colour, an animal's kind and colour, anything carried, delivered \
    or left behind.
    Never name people or guess who they are. Don't mention the camera, the time, the date or any text written over \
    the picture. If something isn't clear, leave it out rather than guess.
    Things merely near each other aren't doing anything together: say someone holds or carries something only when \
    it's clearly in their hands (or an animal's mouth).
    """

    public init() {}

    /// The sentence for an event's picture (the whole view, and a close-up of what began it, if there's one), told
    /// what the camera's detector found in it (its labels, how many of each).
    public func describe(picture: CGImage, closeUp: CGImage?, found: [String: Int]) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        let seen = found.isEmpty ? "" : "The detector found: " + Self.words(found) + ". "
        let response = try await session.respond {
            "\(seen)Describe this picture in one sentence."
            Attachment(picture).label("The whole view")
            if let closeUp {
                Attachment(closeUp).label("A closer look at what moved")
            }
        }
        let sentence = Self.tidy(response.content)
        // An answer that says nothing ("Something.") is no description: the event's said from what was found instead.
        return EventDescription.saysNothing(sentence) ? "" : sentence
    }

    /// Whether a failure's for good (the picture won't be described: declined, or it can't be read as asked), or
    /// only for now (busy, rate-limited, the model not ready), to try again later.
    public static func isFinal(_ error: any Error) -> Bool {
        guard let error = error as? LanguageModelError else { return false }
        switch error {
        case .guardrailViolation, .refusal, .contextSizeExceeded, .unsupportedCapability, .unsupportedTranscriptContent,
             .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return true
        default:
            // (Rate-limited, timed out: later.)
            return false
        }
    }

    /// "2 people, a cat": the labels, plainly.
    static func words(_ found: [String: Int]) -> String {
        found.sorted { $0.key < $1.key }.map { label, count in count == 1 ? "a \(label)" : "\(count) \(label)s" }
            .joined(separator: ", ")
    }

    /// One sentence, without quotes or space round it.
    static func tidy(_ text: String) -> String {
        var sentence = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        if let end = sentence.firstIndex(of: "\n") { sentence = String(sentence[..<end]) }
        return sentence
    }
}

/// Close-ups: the part of a picture round what was found in it.
public enum CloseUp {
    /// The picture round `box` (fractions of the picture, from the top left), with room round it, at least a third of
    /// the picture's height a side (smaller says too little), square where the picture allows. Nil when it'd be most
    /// of the picture anyway.
    public static func crop(_ picture: CGImage, box: CGRect) -> CGImage? {
        let w = Double(picture.width), h = Double(picture.height)
        let side = min(max(max(box.width * w, box.height * h) * 1.5, h / 3), w, h)
        guard side * side < 0.6 * w * h else { return nil }
        let x = min(max(0, box.midX * w - side / 2), w - side)
        let y = min(max(0, box.midY * h - side / 2), h - side)
        return picture.cropping(to: CGRect(x: x.rounded(), y: y.rounded(), width: side.rounded(), height: side.rounded()))
    }
}
