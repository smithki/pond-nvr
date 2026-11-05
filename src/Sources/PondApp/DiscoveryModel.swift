// Cameras on the network that aren't set up: found every way at once (CameraFinder: ONVIF discovery,
// Reolink's own discovery, and a look at the network's addresses) each time the app opens, once a day while
// it stays open, and each time Add Camera opens. Offered in Add Camera, and in the toolbar until added or
// ignored.
import Devices
import Foundation
import PondCore
import SwiftUI

extension AppModel {
    static let lastCameraLookKey = "lastCameraLook"
    static let foundCamerasKey = "foundCameras"
    static let ignoredCamerasKey = "ignoredCameras"

    static func keptFoundCameras() -> [FoundCamera] {
        guard let data = UserDefaults.standard.data(forKey: foundCamerasKey) else { return [] }
        return (try? JSONDecoder().decode([FoundCamera].self, from: data)) ?? []
    }

    /// Found and not set up (by address).
    var camerasNotSetUp: [FoundCamera] {
        let hosts = Set(config?.cameras.map(\.host) ?? [])
        return foundCameras.filter { !hosts.contains($0.host) }
    }

    /// Found, not set up, and not ignored: what the toolbar offers.
    var newCameras: [FoundCamera] { camerasNotSetUp.filter { !isIgnored($0) } }

    /// Found, not set up, and ignored: listed apart, each to show again.
    var ignoredFound: [FoundCamera] { camerasNotSetUp.filter(isIgnored) }

    func isIgnored(_ camera: FoundCamera) -> Bool { ignoredCameras.contains(Self.ignoreKey(camera)) }

    /// A camera is ignored by its MAC address when known (it stays ignored if its address changes), else by
    /// its address and name.
    static func ignoreKey(_ camera: FoundCamera) -> String { camera.mac ?? "\(camera.host) \(camera.name ?? "")" }

    func ignore(_ camera: FoundCamera) {
        withAnimation(.snappy(duration: 0.3)) { _ = ignoredCameras.insert(Self.ignoreKey(camera)) }
        UserDefaults.standard.set(Array(ignoredCameras), forKey: Self.ignoredCamerasKey)
    }

    /// Ignored no more: offered in the toolbar again.
    func showAgain(_ camera: FoundCamera) {
        withAnimation(.snappy(duration: 0.3)) { _ = ignoredCameras.remove(Self.ignoreKey(camera)) }
        UserDefaults.standard.set(Array(ignoredCameras), forKey: Self.ignoredCamerasKey)
    }

    /// Looks again (one look at a time), and keeps what it found.
    func findCameras() async {
        guard !findingCameras else { return }
        // In a demo, its own network's (made up; the real network's cameras aren't its), and not kept.
        if DemoSession.scenario != nil {
            foundCameras = DemoSession.found
            return
        }
        findingCameras = true
        let found = await CameraFinder.find()
        foundCameras = found
        findingCameras = false
        UserDefaults.standard.set(Date(), forKey: Self.lastCameraLookKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(foundCameras), forKey: Self.foundCamerasKey)
    }

    /// Looks again if the last look was a day ago or more (or never).
    func findCamerasIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCameraLookKey) as? Date
        // (A demo's always: it costs nothing, and the real look's time isn't its.)
        if DemoSession.scenario != nil || last.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true { await findCameras() }
    }

    /// Add Camera, starting from a camera found on the network.
    func add(_ camera: FoundCamera) {
        addingFrom = camera
        settingsTab = .cameras
        addingCamera = true
    }
}

extension FoundCamera {
    /// A name to start Add Camera with: its own (from its maker's app, or ONVIF), else what the network
    /// calls it, capitalised.
    var suggestedName: String {
        guard let name else { return hardware ?? "" }
        return maker != nil || answersONVIF ? name : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// What a list says under its name: its address, and its maker or model.
    var detail: String { [host, maker ?? hardware].compactMap { $0 }.joined(separator: " \u{00B7} ") }
}

/// A camera found on the network, in a list: its name and where it is, then its buttons.
struct FoundCameraRow<Actions: View>: View {
    var camera: FoundCamera
    var dimmed = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "video").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.suggestedName.isEmpty ? camera.host : camera.suggestedName)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                Text(camera.detail)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            actions
        }
    }
}
