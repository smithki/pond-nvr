// swift-tools-version: 6.0
// The Mac app: Pond NVR.app's settings, cameras, events and doctor (PondApp), over the recorder (../recorder). make app
// builds it here, with the pond command and the signaling service (for demo mode) beside it, and bundles them all
// (app/: its Info.plist, entitlements and icon).
import PackageDescription

let recorder = ["PondCore", "PondMac", "Ingest", "Control", "Recorder", "HAP", "HAPCamera", "Devices", "Health", "Watch",
                "Detection", "Understanding", "Demo"]

let package = Package(
    name: "PondApp",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../recorder"),
        .package(path: "../signaling"),
        // Updates of the app itself: Sparkle (MIT), a version pinned (docs/release.md, Updates).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // The app: settings and the recorder's state (make app bundles it as Pond NVR.app).
        .executableTarget(name: "PondApp", dependencies: recorder.map { .product(name: $0, package: "recorder") }
                                                         + [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "PondAppTests", dependencies: ["PondApp"] + ["PondCore", "Ingest", "Control", "Watch", "Understanding"]
                                                                       .map { .product(name: $0, package: "recorder") },
                    resources: [.copy("Fixtures")]),
    ]
)
