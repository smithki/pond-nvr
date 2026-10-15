// Reads MP4 boxes back, to check what the writer produced.
struct Box {
    let type: String
    let start: Int        // offset of the box in the file
    let payload: [UInt8]  // after the 8-byte header

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "mvex", "moof", "traf", "dinf"]

    static func parse(_ bytes: [UInt8], base: Int = 0) -> [Box] {
        var out: [Box] = []
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard size >= 8, i + size <= bytes.count else { break }
            out.append(Box(type: String(decoding: bytes[i + 4 ..< i + 8], as: UTF8.self), start: base + i,
                           payload: Array(bytes[i + 8 ..< i + size])))
            i += size
        }
        return out
    }

    var children: [Box] {
        if Box.containers.contains(type) { return Box.parse(payload, base: start + 8) }
        if type == "stsd" { return Box.parse(Array(payload.dropFirst(8)), base: start + 16) }
        return []
    }

    /// The first box of this type anywhere below.
    func find(_ path: String...) -> Box? {
        var current: [Box] = [self]
        for name in path {
            guard let next = current.flatMap(\.children).first(where: { $0.type == name }) else { return nil }
            current = [next]
        }
        return current.first
    }

    func u32(_ at: Int) -> UInt32 {
        UInt32(payload[at]) << 24 | UInt32(payload[at + 1]) << 16 | UInt32(payload[at + 2]) << 8 | UInt32(payload[at + 3])
    }

    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) << 32 | UInt64(u32(at + 4)) }
}
