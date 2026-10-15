// A small argument reader: options are taken out by name, and whatever is left must be the expected
// positional arguments. Unknown options are an error rather than being ignored.

struct Args {
    private(set) var items: [String]

    init(_ items: [String]) { self.items = items }

    /// Removes `--name VALUE` and returns VALUE; nil if absent. Throws if VALUE is missing.
    mutating func option(_ name: String) throws(UsageError) -> String? {
        guard let i = items.firstIndex(of: name) else { return nil }
        guard i + 1 < items.count, !items[i + 1].hasPrefix("--") else { throw UsageError("\(name) needs a value.") }
        let value = items[i + 1]
        items.removeSubrange(i ... i + 1)
        return value
    }

    /// Removes `--name` and says whether it was there.
    mutating func flag(_ name: String) -> Bool {
        guard let i = items.firstIndex(of: name) else { return false }
        items.remove(at: i)
        return true
    }

    /// The next positional argument, or nil.
    mutating func next() -> String? {
        guard let i = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return items.remove(at: i)
    }

    /// Fails if anything was not used.
    func done() throws(UsageError) {
        if let first = items.first {
            throw UsageError(first.hasPrefix("--") ? "Unknown option \(first)." : "Unexpected argument \(first).")
        }
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A failure the command has already explained; carries the exit code.
struct Failure: Error {
    let code: Int32
    init(_ code: Int32 = 1) { self.code = code }
}
