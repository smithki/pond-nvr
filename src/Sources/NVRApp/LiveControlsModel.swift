// A camera's controls from the app: PTZ, presets, night mode and talking back, all through the service's
// control socket (ControlSocket), which has the passwords and keeps each camera's logins. What a camera has
// is in its settings (`device.controls`, worked out when it's identified), so the app shows only what works.
import AVFoundation
import Devices
import Foundation
import NVRCore
import SwiftUI

extension AppModel {
    var controlClient: ControlClient { ControlClient(path: ControlSocket.path(nextTo: store.path)) }

    /// What can be controlled on this camera (nil: nothing, or not known yet).
    func controls(for camera: Config.Camera) -> Config.Controls? {
        guard let controls = camera.device?.controls, !controls.isEmpty else { return nil }
        return controls
    }

    /// Asks the service; a failure is shown on the camera for a moment.
    @discardableResult
    func control(_ camera: String, _ request: ControlSocket.Request) async -> ControlSocket.Reply? {
        let reply = await controlClient.ask(request)
        // Private or waking (the service knew before the app did): not a failure to show; the dock catches up.
        if reply.asleep == true {
            if !isPrivate(camera), !wakingCameras.contains(camera) {
                withAnimation(.snappy(duration: 0.3)) { _ = wakingCameras.insert(camera) }
            }
            return nil
        }
        if let error = reply.error {
            var serviceDown = true
            if case .running = serviceState { serviceDown = false }
            showControlError(camera, error == .unreachable && serviceDown ? "The service isn\u{2019}t running" : error.description)
            return nil
        }
        return reply
    }

    /// Says what went wrong on the camera for a few seconds.
    func showControlError(_ camera: String, _ words: String) {
        controlError[camera] = words
        Task {
            try? await Task.sleep(for: .seconds(4))
            if controlError[camera] == words { controlError[camera] = nil }
        }
    }

    func move(_ camera: String, _ velocity: PTZVelocity) async {
        // Moved by hand: no longer at a position (its picture isn't taken from here).
        if !velocity.isStill { atPreset[camera] = nil }
        await control(camera, .init(camera: camera, action: velocity.isStill ? "ptz.stop" : "ptz.move", velocity: velocity))
    }

    func loadPresets(_ camera: String, animated: Bool = false) async {
        if let list = await control(camera, .init(camera: camera, action: "ptz.presets"))?.presets {
            loadPresetPictures(camera, list)
            rememberOrder(camera, list)
            AppModel.keepPresets(camera, list)
            if animated {
                withAnimation(.spring(duration: 0.45, bounce: 0.3)) { presets[camera] = list }
            } else {
                presets[camera] = list
            }
        }
    }

    func goTo(_ camera: String, preset: String) async {
        guard await control(camera, .init(camera: camera, action: "ptz.goto", preset: preset)) != nil else { return }
        takePresetPictureOnArrival(camera, preset)
    }

    func savePreset(_ camera: String, name: String, replacing: String? = nil) async {
        guard let saved = await control(camera, .init(camera: camera, action: "ptz.save", preset: replacing, name: name))?.preset
        else { return }
        // It's where it points now.
        atPreset[camera] = saved.id
        takePresetPicture(camera, saved.id)
        // A new one springs into the dock (or drops into More).
        await loadPresets(camera, animated: replacing == nil)
        if replacing == nil { justKept = AppModel.presetKey(camera, saved.id) }
    }

    func removePreset(_ camera: String, preset: String) async {
        guard await control(camera, .init(camera: camera, action: "ptz.remove", preset: preset)) != nil else { return }
        // It shrinks away and the others close up (the next from More, if any, springing into the dock).
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { presets[camera]?.removeAll { $0.id == preset } }
        AppModel.keepPresets(camera, presets[camera] ?? [])
        forgetPresetPicture(camera, preset)
        forgetOrder(camera, preset)
    }

    /// Every item's value, read from the camera.
    func loadItemValues(_ camera: String) async {
        if let values = await control(camera, .init(camera: camera, action: "items.values"))?.values {
            itemValues[camera, default: [:]].merge(values) { $1 }
        }
    }

    /// Sets an item, shown at once and put back if the camera refuses. While it's back from privacy mode, the
    /// service keeps it until it is (marked waiting meanwhile).
    func setItem(_ camera: String, _ item: String, _ value: Config.Controls.Value) async {
        let before = itemValues[camera]?[item]
        itemValues[camera, default: [:]][item] = value
        guard let reply = await control(camera, .init(camera: camera, action: "item.set", item: item, value: value)) else {
            itemValues[camera, default: [:]][item] = before
            return
        }
        if reply.queued == true {
            pendingSettings[camera, default: [:]][item] = value
        } else {
            pendingSettings[camera]?[item] = nil
        }
    }

    /// Set to this once the camera is back from its privacy mode.
    func isPending(_ camera: String, _ item: String) -> Bool { pendingSettings[camera]?[item] != nil }

    func doItem(_ camera: String, _ item: String) async {
        await control(camera, .init(camera: camera, action: "item.do", item: item))
    }

    // MARK: Privacy

    var privacyPath: String { PrivacyState.path(nextTo: store.path) }

    /// Private in Pond, or on the camera itself.
    func isPrivate(_ camera: String) -> Bool { privateCameras.contains(camera) || privateOnCamera.contains(camera) }

    /// Made public after its own privacy mode, and not sending video yet.
    func isWaking(_ camera: String) -> Bool { wakingCameras.contains(camera) }

    /// Can't be used just now (moved, talked through, its actions): private, or waking.
    func isAsleep(_ camera: String) -> Bool { isPrivate(camera) || isWaking(camera) }

    /// Why a control is off while it's asleep.
    func asleepReason(_ camera: String) -> String {
        isWaking(camera) ? "Not until it\u{2019}s back from privacy mode" : "Not while it\u{2019}s private"
    }

    /// Private on the camera itself only (Pond can't turn that off).
    func isPrivateOnCameraOnly(_ camera: String) -> Bool { privateOnCamera.contains(camera) && !privateCameras.contains(camera) }

    /// Which cameras are private, as kept (made so here, from the CLI, or by the Home app turning one off).
    func refreshPrivacy() {
        guard Date().timeIntervalSince(privacyChanged) > 1.5 else { return }
        let state = PrivacyState(path: privacyPath)
        // (Other Ponds' cameras' as they last said.)
        let others = remotePonds.flatMap { $0.cameras ?? [] }.filter(\.isPrivate).map(\.id)
        let now = state.privateCameras.union(others), onCamera = state.privateOnCamera
        if now != privateCameras || onCamera != privateOnCamera {
            withAnimation(.snappy(duration: 0.3)) {
                privateCameras = now
                privateOnCamera = onCamera
            }
        }
        let waking = state.wakingCameras, pending = state.allPending
        if waking != wakingCameras { withAnimation(.snappy(duration: 0.3)) { wakingCameras = waking } }
        if pending != pendingSettings {
            // What was set meanwhile is read from the camera again.
            for (camera, items) in pendingSettings where items.keys.contains(where: { pending[camera]?[$0] == nil }) {
                Task { await loadItemValues(camera) }
            }
            pendingSettings = pending
        }
    }

    /// Makes a camera private or not: shown at once; through the service, which applies it (and has the camera
    /// follow, where it can), or kept for it to apply when it starts.
    func setPrivacy(_ camera: String, _ on: Bool) async {
        privacyChanged = Date()
        // Not talking through a camera made private.
        if on, let talking, talking.camera == camera {
            talking.stop()
            self.talking = nil
            talkLevel = 0
        }
        withAnimation(.snappy(duration: 0.3)) {
            if on { privateCameras.insert(camera) } else { privateCameras.remove(camera) }
        }
        if controlClient.isAvailable {
            if let reply = await control(camera, .init(camera: camera, action: "privacy.set", value: .on(on))) {
                // Waking at once (not when the file's next read): its first failures to connect aren't shown. (Another
                // Pond's camera's answer is about that Pond's.)
                if ControlSocket.RemotePond.split(camera) == nil {
                    withAnimation(.snappy(duration: 0.3)) { wakingCameras = Set(reply.wakingCameras ?? []) }
                }
            } else {
                refreshPrivacy()
            }
        } else {
            PrivacyState(path: privacyPath).set(camera, private: on)
        }
    }

    /// Starts or stops talking through a camera (one at a time).
    func toggleTalk(_ camera: String) async {
        if let talking {
            let was = talking.camera
            talking.stop()
            self.talking = nil
            talkLevel = 0
            if was == camera { return }
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            showControlError(camera, "This Mac has no microphone")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            showControlError(camera, "Pond may not use the microphone (System Settings › Privacy & Security › Microphone)")
            return
        }
        let talker = Talker(camera: camera)
        talking = talker
        do throws(ControlFailure) {
            try await talker.start(client: controlClient) { [weak self] level in
                Task { @MainActor in if self?.talking === talker { self?.talkLevel = level } }
            }
        } catch {
            if talking === talker { talking = nil }
            showControlError(camera, error == .notSupported ? "This camera can\u{2019}t be talked through" : error.description)
        }
    }
}

/// The microphone to a camera's speaker, through the service: the connection opens first and carries silence
/// while the microphone starts (cameras take a moment to start their speaker), then the voice, converted to
/// the camera's rate as it's captured.
final class Talker: @unchecked Sendable {
    let camera: String
    private let engine = AVAudioEngine()
    private var link: ControlTalk?
    private let lock = NSLock()
    private var voiceStarted = false
    private var stopped = false

    init(camera: String) { self.camera = camera }

    func start(client: ControlClient, level: @escaping @Sendable (Double) -> Void) async throws(ControlFailure) {
        let link = try await client.talk(camera: camera)
        lock.withLock { self.link = link }
        // Silence, 20 ms at a time, until the voice takes over.
        let piece = Int(link.sampleRate / 50)
        Thread.detachNewThread { [self] in
            while lock.withLock({ !voiceStarted && !stopped }) {
                try? link.send([Int16](repeating: 0, count: piece))
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let input = engine.inputNode
        let from = input.outputFormat(forBus: 0)
        guard let to = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: link.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: from, to: to) else {
            stop()
            throw .failed("the microphone\u{2019}s sound can\u{2019}t be converted")
        }
        // 100 ms at a time (the shortest a tap gives), sent as it comes.
        do {
            // (Swift's form of installTapOnBus:bufferSize:format:error:block:, which throws.)
            try input.__installTap(onBus: 0, bufferSize: AVAudioFrameCount(from.sampleRate / 10), format: from,
                                   error: ()) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * to.sampleRate / from.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.int16ChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            self.lock.withLock { self.voiceStarted = true }
            try? link.send(samples)
            // How loud, for the button.
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))) / 32768
            level(min(1, rms * 4))
            }
            try engine.start()
        } catch {
            stop()
            throw .failed("the microphone didn\u{2019}t start")
        }
    }

    func stop() {
        let link = lock.withLock { () -> ControlTalk? in
            stopped = true
            defer { self.link = nil }
            return self.link
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        link?.close()
    }
}
