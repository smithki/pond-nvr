// swift-tools-version: 6.0
// The recorder: everything Pond does on the Mac (recording, HomeKit, detection, search, remote access, the pond
// command), the app aside (../macos). Modules that need only Foundation build on Linux too, so `make test-docker` can
// run their tests in a container. Modules that need Apple frameworks (Security, VideoToolbox, Core ML, Foundation
// Models, Network) are added below only on macOS. Remote access speaks the protocol in ../protocol; its tests run the
// signaling service from ../signaling.
import PackageDescription

var commandDependencies: [Target.Dependency] = ["PondCLI", "PondCore", "Ingest", "Recorder", "Control"]
let dependencies: [Package.Dependency] = [.package(path: "../protocol"), .package(path: "../signaling")]
var products: [Product] = [.executable(name: "pond", targets: ["pond"])]
/// What the app (../macos) uses, as libraries.
var libraries = ["PondCore", "Ingest", "Recorder", "Control"]
var targets: [Target] = [
    .target(name: "PondCore"),
    .target(name: "Ingest"),
    .target(name: "Media"),
    .target(name: "Recorder", dependencies: ["Ingest", "Media", "PondCore"]),
    .target(name: "Control", dependencies: ["PondCore", "Ingest"]),
    .target(name: "PondCLI", dependencies: ["PondCore", "Ingest", "Recorder", "Control"]),
    .testTarget(name: "PondCoreTests", dependencies: ["PondCore"]),
    .testTarget(name: "IngestTests", dependencies: ["Ingest"]),
    .testTarget(name: "MediaTests", dependencies: ["Media"]),
    .testTarget(name: "RecorderTests", dependencies: ["Recorder", "Ingest", "Media", "PondCore"]),
    .testTarget(name: "PondCLITests", dependencies: ["PondCLI", "PondCore", "Ingest", "Recorder", "Control"]),
]

#if os(macOS)
targets += [
    // HomeKit: its pairing and sessions use CryptoKit (SHA-512, Ed25519, X25519, ChaCha20-Poly1305).
    .target(name: "HAP"),
    .testTarget(name: "HAPTests", dependencies: ["HAP"]),
    .target(name: "PondMac", dependencies: ["PondCore"]),   // Keychain; later VideoToolbox, Core ML, ...
    // Cameras as HomeKit accessories: the accessory, snapshots (VideoToolbox), the Keychain record.
    .target(name: "HAPCamera", dependencies: ["Media", "HAP", "PondCore", "Ingest", "Devices"]),
    // Its fixture is read from beside the tests (#filePath), not bundled.
    .testTarget(name: "HAPCameraTests", dependencies: ["HAPCamera", "HAP", "PondCore", "Ingest", "Devices"],
                exclude: ["Fixtures"]),
    .testTarget(name: "PondMacTests", dependencies: ["PondMac"]),
    // Remote access: identities kept, pairing hosted, paths, the session, and the API over it (the protocol's
    // envelopes, keys and channel: ../protocol).
    .target(name: "Remote", dependencies: ["PondCore", .product(name: "PondProtocol", package: "protocol"),
                                          .product(name: "SignalProtocol", package: "protocol"),
                                          .product(name: "Traversal", package: "protocol"), "HAPCamera", "Ingest", "Media",
                                          "Devices", "Watch", "Understanding"]),
    .testTarget(name: "RemoteTests", dependencies: ["Remote", "PondCore", .product(name: "PondProtocol", package: "protocol"),
                                                    .product(name: "Signal", package: "signaling"),
                                                    .product(name: "Traversal", package: "protocol"), "HAPCamera", "Ingest",
                                                    "Devices", "Watch", "Understanding"]),
]
// Demo mode: made-up cameras (scenes drawn and encoded as a camera's stream, their controls, what's found in them).
targets.append(.target(name: "Demo", dependencies: ["PondCore", "Ingest", "HAPCamera", "Devices", "Detection", "Recorder", "Watch"]))
targets.append(.testTarget(name: "DemoTests", dependencies: ["Demo", "PondCore", "Ingest", "Detection", "HAPCamera", "Recorder"]))
// Camera health for the doctor, kept in Pond's database (SQLite, which macOS has).
targets.append(.target(name: "Health", dependencies: ["PondCore"], linkerSettings: [.linkedLibrary("sqlite3")]))
targets.append(.testTarget(name: "HealthTests", dependencies: ["Health", "PondCore"]))
// What cameras say they are and what they offer, brand by brand (Reolink, ONVIF).
targets.append(.target(name: "Devices", dependencies: ["PondCore", "Ingest", "Understanding"]))
targets.append(.testTarget(name: "DevicesTests", dependencies: ["Devices", "PondCore", "Understanding"]))
// Detection: a model (built in, or added) run on the Neural Engine, its answers in Pond's terms.
targets.append(.target(name: "Detection"))
targets.append(.testTarget(name: "DetectionTests", dependencies: ["Detection"]))
// Watching the cameras: their pictures decoded, motion, the model, tracks, and events kept.
targets.append(.target(name: "Watch", dependencies: ["Detection", "Ingest", "PondCore", "Recorder", "Understanding"],
                      linkerSettings: [.linkedLibrary("sqlite3")]))
targets.append(.testTarget(name: "WatchTests", dependencies: ["Watch", "Detection", "PondCore", "Recorder", "Understanding"]))
// The soak: video decoding's memory with many cameras (4K, made up) for minutes at a time. Off in the usual tests;
// scripts/soak.sh runs it, with a watchdog.
targets.append(.testTarget(name: "SoakTests", dependencies: ["Watch", "HAPCamera", "PondCore"]))
// Understanding what was seen: a sentence an event (the Mac's own language model), and embeddings of pictures and
// words alike (SigLIP 2), for search.
targets.append(.target(name: "Understanding", dependencies: ["PondCore"]))
targets.append(.testTarget(name: "UnderstandingTests", dependencies: ["Understanding"], resources: [.copy("Fixtures")]))
commandDependencies += ["PondMac", "HAPCamera", "HAP", "Devices", "Health", "Detection", "Watch", "Understanding", "Remote", "Demo",
                        .product(name: "PondProtocol", package: "protocol")]
libraries += ["PondMac", "HAP", "HAPCamera", "Devices", "Health", "Watch", "Detection", "Understanding", "Demo"]
#endif

targets.append(.executableTarget(name: "pond", dependencies: commandDependencies))
products += libraries.map { .library(name: $0, targets: [$0]) }

let package = Package(
    name: "PondRecorder",
    platforms: [.macOS("27.0")],
    products: products,
    dependencies: dependencies,
    targets: targets
)
