// Words to the token ids a text encoder takes: byte-pair encoding as a Hugging Face tokenizer.json describes it, the
// kind SigLIP 2's text side has (Gemma's: spaces become "▁", no space added in front, characters the vocabulary
// lacks spelled out as their UTF-8 bytes, an end-of-sequence token after, padding to a fixed length).
import Foundation

public struct BPETokenizer: Sendable {
    /// Each token's id, by its text.
    let vocabulary: [String: Int32]
    /// Each pair's rank (lower merges first), by the pair's two texts joined by `separator`.
    let ranks: [String: Int]
    let unknown: Int32
    /// After every sequence, if the tokenizer adds it.
    let end: Int32?

    static let separator = "\u{0}"
    static let space = "\u{2581}"

    public enum Failure: Error, Equatable {
        case unreadable
        case notBPE(String)
    }

    /// From a tokenizer.json (a BPE one).
    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any] else { throw Failure.unreadable }
        guard (model["type"] as? String) == "BPE", let vocabulary = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [Any] else { throw Failure.notBPE(model["type"] as? String ?? "?") }
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() {
            // (Either a pair, or one string with a space between, by the format's version.)
            if let pair = merge as? [String], pair.count == 2 {
                ranks[pair[0] + Self.separator + pair[1]] = rank
            } else if let joined = merge as? String, let space = joined.firstIndex(of: " ") {
                ranks[String(joined[..<space]) + Self.separator + String(joined[joined.index(after: space)...])] = rank
            }
        }
        self.vocabulary = vocabulary.mapValues { Int32($0) }
        self.ranks = ranks
        unknown = Int32(vocabulary[(model["unk_token"] as? String) ?? "<unk>"] ?? 3)
        // The end-of-sequence token the template puts after a sequence, if it does.
        let processor = json["post_processor"] as? [String: Any]
        let special = (processor?["special_tokens"] as? [String: Any])?.values.first as? [String: Any]
        end = (special?["ids"] as? [Int])?.first.map { Int32($0) }
    }

    init(vocabulary: [String: Int32], merges: [(String, String)], unknown: Int32, end: Int32?) {
        self.vocabulary = vocabulary
        ranks = Dictionary(uniqueKeysWithValues: merges.enumerated().map { ($1.0 + Self.separator + $1.1, $0) })
        self.unknown = unknown
        self.end = end
    }

    /// The ids for `text` (with the end token, if it has one), cut to `length` and padded to it with `pad`.
    public func ids(_ text: String, length: Int, pad: Int32 = 0) -> [Int32] {
        var ids = encode(text)
        if let end { ids = Array(ids.prefix(length - 1)) + [end] } else { ids = Array(ids.prefix(length)) }
        return ids + Array(repeating: pad, count: max(0, length - ids.count))
    }

    /// The tokens of `text`, without the end token or padding.
    public func encode(_ text: String) -> [Int32] {
        guard !text.isEmpty else { return [] }
        // Each character a symbol, then the best-ranked neighbouring pair joined, again and again.
        var symbols = text.replacingOccurrences(of: " ", with: Self.space).map(String.init)
        while symbols.count > 1 {
            var best: (rank: Int, at: Int)?
            for i in 0 ..< symbols.count - 1 {
                if let rank = ranks[symbols[i] + Self.separator + symbols[i + 1]], rank < best?.rank ?? .max { best = (rank, i) }
            }
            guard let best else { break }
            symbols[best.at] += symbols[best.at + 1]
            symbols.remove(at: best.at + 1)
        }
        return symbols.flatMap { symbol -> [Int32] in
            if let id = vocabulary[symbol] { return [id] }
            // Not in the vocabulary: its bytes, as <0xNN> tokens.
            let bytes = Array(symbol.utf8).map { vocabulary[String(format: "<0x%02X>", $0)] }
            return bytes.allSatisfy { $0 != nil } ? bytes.compactMap { $0 } : [unknown]
        }
    }
}
