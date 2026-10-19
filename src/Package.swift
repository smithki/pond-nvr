// swift-tools-version: 6.0
// The NVR as one Swift package. Modules that need only Foundation build on Linux too, so `make test-docker`
// can run their tests in a container. Modules that need Apple frameworks (Security, VideoToolbox, Core ML,
// Foundation Models, Network) are added below only on macOS.
import PackageDescription

var commandDependencies: [Target.Dependency] = ["NVRCLI", "NVRCore", "Ingest", "Recorder", "Control"]
var targets: [Target] = [
    .target(name: "NVRCore"),
    .target(name: "Ingest"),
    .target(name: "Media"),
    .target(name: "Recorder", dependencies: ["Ingest", "Media", "NVRCore"]),
    .target(name: "Control", dependencies: ["NVRCore", "Ingest"]),
    .target(name: "NVRCLI", dependencies: ["NVRCore", "Ingest", "Recorder", "Control"]),
    .testTarget(name: "NVRCoreTests", dependencies: ["NVRCore"]),
    .testTarget(name: "IngestTests", dependencies: ["Ingest"]),
    .testTarget(name: "MediaTests", dependencies: ["Media"]),
    .testTarget(name: "RecorderTests", dependencies: ["Recorder", "Ingest", "Media", "NVRCore"]),
    .testTarget(name: "NVRCLITests", dependencies: ["NVRCLI", "NVRCore", "Ingest", "Recorder", "Control"]),
]

#if os(macOS)
targets += [
    // HomeKit: its pairing and sessions use CryptoKit (SHA-512, Ed25519, X25519, ChaCha20-Poly1305).
    .target(name: "HAP"),
    .testTarget(name: "HAPTests", dependencies: ["HAP"]),
    .target(name: "NVRMac", dependencies: ["NVRCore"]),   // Keychain; later VideoToolbox, Core ML, ...
    // Cameras as HomeKit accessories: the accessory, snapshots (VideoToolbox), the Keychain record.
    .target(name: "HAPCamera", dependencies: ["Media", "HAP", "NVRCore", "Ingest", "Devices"]),
    // Its fixture is read from beside the tests (#filePath), not bundled.
    .testTarget(name: "HAPCameraTests", dependencies: ["HAPCamera", "HAP", "NVRCore", "Ingest", "Devices"],
                exclude: ["Fixtures"]),
    .testTarget(name: "NVRMacTests", dependencies: ["NVRMac"]),
]
// Camera health for the doctor, kept in Pond's database (SQLite, which macOS has).
targets.append(.target(name: "Health", dependencies: ["NVRCore"], linkerSettings: [.linkedLibrary("sqlite3")]))
targets.append(.testTarget(name: "HealthTests", dependencies: ["Health", "NVRCore"]))
// What cameras say they are and what they offer, brand by brand (Reolink, ONVIF).
targets.append(.target(name: "Devices", dependencies: ["NVRCore", "Ingest"]))
targets.append(.testTarget(name: "DevicesTests", dependencies: ["Devices", "NVRCore"]))
// Detection: a model (built in, or added) run on the Neural Engine, its answers in Pond's terms.
targets.append(.target(name: "Detection"))
targets.append(.testTarget(name: "DetectionTests", dependencies: ["Detection"]))
// Watching the cameras: their pictures decoded, motion, the model, tracks, and events kept.
targets.append(.target(name: "Watch", dependencies: ["Detection", "Ingest", "NVRCore"], linkerSettings: [.linkedLibrary("sqlite3")]))
targets.append(.testTarget(name: "WatchTests", dependencies: ["Watch", "Detection", "NVRCore"]))
commandDependencies += ["NVRMac", "HAPCamera", "HAP", "Devices", "Health", "Detection", "Watch"]
// The app: settings and the recorder's state (make app bundles it as NVR.app).
targets.append(.executableTarget(name: "NVRApp", dependencies: ["NVRCore", "NVRMac", "Ingest", "Control", "Recorder",
                                                               "HAP", "HAPCamera", "Devices", "Health", "Watch", "Detection"]))
targets.append(.testTarget(name: "NVRAppTests", dependencies: ["NVRApp", "NVRCore", "Ingest", "Control", "Watch"],
                           resources: [.copy("Fixtures")]))
#endif

targets.append(.executableTarget(name: "pond", dependencies: commandDependencies))

let package = Package(
    name: "Pond",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "pond", targets: ["pond"])],
    targets: targets
)
