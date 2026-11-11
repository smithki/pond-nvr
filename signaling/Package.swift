// swift-tools-version: 6.0
// The signaling service: a blind courier for sealed envelopes between Ponds and their devices, and a STUN responder
// (deploy/ runs it; docs/remote.md). Plain Swift and POSIX, so it builds on Linux. Its messages are the protocol's
// (../protocol).
import PackageDescription

let package = Package(
    name: "PondSignal",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Signal", targets: ["Signal"]),
        .executable(name: "pond-signal", targets: ["pond-signal"]),
    ],
    dependencies: [.package(path: "../protocol")],
    targets: [
        .target(name: "Signal", dependencies: [.product(name: "Traversal", package: "protocol"),
                                               .product(name: "SignalProtocol", package: "protocol")]),
        .executableTarget(name: "pond-signal", dependencies: ["Signal"]),
    ]
)
