// Where the app keeps what it remembers (the rail, the timeline's zoom, cameras found, the doctor's thresholds…):
// the app's own preferences, or, in a demo, a store of the demo's own. A demo is the same app (its bundle, its
// identifier), so without this it shared them with the real Pond: what was changed in one showed in the other, and a
// demo's windows remembered over the real one's (each demo also opens its windows afresh: PondApp, restoration).
import Foundation

enum AppDefaults {
    /// In demo mode (`--demo`), known from the launch's arguments alone (before the scenario is made).
    static let isDemo = CommandLine.arguments.contains("--demo")

    /// The store everything the app remembers goes in: `camera.pond.demo` in a demo, else the app's own.
    nonisolated(unsafe) static let store: UserDefaults =
        isDemo ? UserDefaults(suiteName: "camera.pond.demo") ?? .standard : .standard
}
