// pond-signal: Pond's signaling service, to run on a server of one's own (see deploy/). Passes sealed envelopes
// between paired Ponds and devices, and answers STUN; reads none of them, keeps nothing.
//
//   pond-signal [--port 8080] [--stun 3478]
import Foundation
import Signal

func option(_ name: String, _ fallback: UInt16, in args: [String] = Array(CommandLine.arguments.dropFirst())) -> UInt16 {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let value = UInt16(args[i + 1]) else { return fallback }
    return value
}
let signaling = SignalServer(port: option("--port", 8080))
let stun = STUNResponder(port: option("--stun", 3478))
do {
    try signaling.start()
    try stun.start()
    print("STUN on UDP port \(stun.boundPort)")
} catch {
    FileHandle.standardError.write(Data("✗ pond-signal couldn't start: \(error)\n".utf8))
    exit(1)
}
while true { sleep(3600) }
