// pond-signal: Pond's signaling service, to run on a server of one's own (see deploy/). Passes sealed envelopes
// between paired Ponds and devices, and answers STUN; reads none of them, keeps nothing. STUN answers on two ports
// (the second one more, by default): a Pond asking at both learns whether its router shows the world a different
// port for each destination (a "symmetric" NAT), for saying why a connection can't be made.
//
//   pond-signal [--port 8080] [--stun 3478] [--stun-alternate 3479]
import Foundation
import Signal

func option(_ name: String, _ fallback: UInt16, in args: [String] = Array(CommandLine.arguments.dropFirst())) -> UInt16 {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let value = UInt16(args[i + 1]) else { return fallback }
    return value
}
let signaling = SignalServer(port: option("--port", 8080))
let stun = STUNResponder(port: option("--stun", 3478))
let alternate = STUNResponder(port: option("--stun-alternate", option("--stun", 3478) &+ 1))
do {
    try signaling.start()
    try stun.start()
    try alternate.start()
    print("STUN on UDP ports \(stun.boundPort) and \(alternate.boundPort)")
} catch {
    FileHandle.standardError.write(Data("✗ pond-signal couldn't start: \(error)\n".utf8))
    exit(1)
}
while true { sleep(3600) }
