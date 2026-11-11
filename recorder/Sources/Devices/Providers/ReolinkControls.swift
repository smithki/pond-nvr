// Reolink's controls through its own HTTP API, where it has them: PTZ (PtzCtrl's directions and zoom, and its
// presets) and day/night (the ISP's dayNight). What a camera can do is in GetAbility, asked once. Talking back
// isn't in this API (Reolink's apps use its proprietary protocol for it), so that is left to ONVIF.
import Foundation
import PondCore

/// What GetAbility says, as versions: 0 for a feature the camera hasn't.
public struct ReolinkAbility: Sendable, Equatable {
    /// Channel 0's (the camera's own), and the device's.
    public var channel: [String: Int]
    public var device: [String: Int]

    public func has(_ name: String) -> Bool { (channel[name] ?? device[name] ?? 0) > 0 }

    static func parse(_ value: [String: Any]) -> ReolinkAbility? {
        guard let ability = value["Ability"] as? [String: Any] else { return nil }
        func versions(_ map: [String: Any]?) -> [String: Int] {
            (map ?? [:]).compactMapValues { ($0 as? [String: Any])?["ver"] as? Int }
        }
        let channel = (ability["abilityChn"] as? [[String: Any]])?.first
        return ReolinkAbility(channel: versions(channel), device: versions(ability))
    }
}

extension ReolinkAPI.Failure {
    var control: ControlFailure {
        switch self {
        case .notSupported: .notSupported
        case .unreachable: .unreachable
        case .loginRefused: .loginRefused
        case .loggedOut: .failed("logged out")
        case .tooManyLogins: .busy
        case let .unexpected(why): .failed(why)
        }
    }
}

extension ReolinkAPI {
    /// A command, logging in again once if the login ran out; failures as a control's.
    func control(_ cmd: String, _ param: [String: Any] = [:]) async throws(ControlFailure) -> [String: Any] {
        do throws(Failure) {
            do {
                return try await command(cmd, param: param)
            } catch .loggedOut {
                try await login()
                return try await command(cmd, param: param)
            }
        } catch {
            throw error.control
        }
    }
}

extension CameraSessions {
    /// The camera's GetAbility, asked once: no if it doesn't answer Reolink's API, unknown if it couldn't be
    /// asked just now.
    func reolinkAbility(_ access: CameraAccess) async -> Offer<ReolinkAbility> {
        if let known = reolinkAbilities[access] { return .yes(known) }
        let api = reolink(access)
        do throws(ControlFailure) {
            guard let ability = ReolinkAbility.parse(try await api.control("GetAbility", ["User": ["userName": access.username]]))
            else { return .no }
            reolinkAbilities[access] = ability
            return .yes(ability)
        } catch .unreachable, .busy, .loginRefused {
            return .unknown
        } catch {
            return .no
        }
    }
}

final class ReolinkPTZ: PTZControl {
    let api: ReolinkAPI
    let abilities: Config.Controls.PTZ
    /// It takes a speed with a move (else its own).
    let speeds: Bool

    init(api: ReolinkAPI, ability: ReolinkAbility) {
        self.api = api
        speeds = ability.has("supportPtzSpeed")
        abilities = Config.Controls.PTZ(provider: "reolink", panTilt: ability.has("supportPt") || ability.has("ptzCtrl"),
                                        zoom: ability.has("supportZoom"), presets: ability.has("ptzPreset") ? 64 : 0)
    }

    /// Reolink's direction for a move (its PTZ moves one way at a time: pan and tilt together on the
    /// diagonals, or zoom), and a speed of 1–64 from the move's strength.
    static func operation(_ v: PTZVelocity) -> (op: String, speed: Int)? {
        let threshold = 0.2
        let pan = abs(v.pan) >= threshold ? (v.pan > 0 ? "Right" : "Left") : ""
        let tilt = abs(v.tilt) >= threshold ? (v.tilt > 0 ? "Up" : "Down") : ""
        let strength = max(abs(v.pan), abs(v.tilt))
        if !pan.isEmpty || !tilt.isEmpty {
            // LeftUp, RightDown and so on.
            return (pan + tilt, max(1, min(64, Int((strength * 64).rounded()))))
        }
        if abs(v.zoom) >= threshold {
            return (v.zoom > 0 ? "ZoomInc" : "ZoomDec", max(1, min(64, Int((abs(v.zoom) * 64).rounded()))))
        }
        return nil
    }

    func move(_ velocity: PTZVelocity) async throws(ControlFailure) {
        guard let (op, speed) = Self.operation(velocity) else { return try await stop() }
        var param: [String: Any] = ["channel": 0, "op": op]
        if speeds { param["speed"] = speed }
        _ = try await api.control("PtzCtrl", param)
    }

    func stop() async throws(ControlFailure) {
        _ = try await api.control("PtzCtrl", ["channel": 0, "op": "Stop"])
    }

    /// Its kept positions (enabled ones), from GetPtzPreset.
    static func presets(in value: [String: Any]) -> [PTZPreset] {
        ((value["PtzPreset"] as? [[String: Any]]) ?? []).compactMap { preset in
            guard (preset["enable"] as? Int) == 1, let id = preset["id"] as? Int else { return nil }
            return PTZPreset(id: String(id), name: (preset["name"] as? String) ?? "Position \(id + 1)")
        }
    }

    func presets() async throws(ControlFailure) -> [PTZPreset] {
        Self.presets(in: try await api.control("GetPtzPreset", ["channel": 0]))
    }

    func goTo(_ preset: String) async throws(ControlFailure) {
        guard let id = Int(preset) else { throw .failed("no such preset") }
        _ = try await api.control("PtzCtrl", ["channel": 0, "op": "ToPos", "id": id, "speed": 32])
    }

    func savePreset(_ name: String, replacing: String?) async throws(ControlFailure) -> PTZPreset {
        let id: Int
        if let replacing, let existing = Int(replacing) {
            id = existing
        } else {
            // The first place not in use.
            let all = (try await api.control("GetPtzPreset", ["channel": 0])["PtzPreset"] as? [[String: Any]]) ?? []
            guard let free = all.first(where: { ($0["enable"] as? Int) != 1 })?["id"] as? Int else {
                throw .failed("every preset place is in use")
            }
            id = free
        }
        _ = try await api.control("SetPtzPreset", ["PtzPreset": ["channel": 0, "enable": 1, "id": id, "name": name]])
        return PTZPreset(id: String(id), name: name)
    }

    func removePreset(_ preset: String) async throws(ControlFailure) {
        guard let id = Int(preset) else { throw .failed("no such preset") }
        _ = try await api.control("SetPtzPreset", ["PtzPreset": ["channel": 0, "enable": 0, "id": id]])
    }
}

/// Day and night through the ISP: dayNight "Auto", "Color", "Black&White".
final class ReolinkNightMode: ItemControl {
    let api: ReolinkAPI
    let item = NightMode.item(NightMode.allCases, provider: "reolink")

    init(api: ReolinkAPI) { self.api = api }

    func value() async throws(ControlFailure) -> Config.Controls.Value? { .choice(try await nightMode().rawValue) }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .choice(text) = value, let mode = NightMode(rawValue: text) else { throw .failed("auto, day or night") }
        try await setNightMode(mode)
    }

    static func mode(_ value: String) -> NightMode? {
        switch value.lowercased() {
        case "auto": .auto
        case "color": .day
        case "black&white": .night
        default: nil
        }
    }

    static func value(_ mode: NightMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .day: "Color"
        case .night: "Black&White"
        }
    }

    func nightMode() async throws(ControlFailure) -> NightMode {
        let value = try await api.control("GetIsp", ["channel": 0])
        guard let text = (value["Isp"] as? [String: Any])?["dayNight"] as? String, let mode = Self.mode(text) else {
            throw .notSupported
        }
        return mode
    }

    func setNightMode(_ mode: NightMode) async throws(ControlFailure) {
        _ = try await api.control("SetIsp", ["Isp": ["channel": 0, "dayNight": Self.value(mode)]])
    }
}

/// The speaker's volume, 0–100: GetAudioCfg / SetAudioCfg's volume.
final class ReolinkVolume: ItemControl {
    let api: ReolinkAPI
    let item = Config.Controls.Item(id: "speakerVolume", title: "Speaker", symbol: "speaker.wave.2", group: .sound, order: 10,
                                    kind: .slider(min: 0, max: 100, step: 1), provider: "reolink")

    init(api: ReolinkAPI) { self.api = api }

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        guard let volume = (try await api.control("GetAudioCfg", ["channel": 0])["AudioCfg"] as? [String: Any])?["volume"] as? Int
        else { throw .notSupported }
        return .number(Double(volume))
    }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .number(volume) = value else { throw .failed("a number") }
        _ = try await api.control("SetAudioCfg", ["AudioCfg": ["channel": 0, "volume": Int(volume.rounded())]])
    }
}

/// The infrared lights for the dark: on their own by the light (Auto), or off (GetIrLights, SetIrLights).
final class ReolinkIRLights: ItemControl {
    let api: ReolinkAPI
    let item = Config.Controls.Item(id: "irLights", title: "IR Lights", symbol: "rays", group: .light, order: 10,
                                    kind: .choice([.init(value: "auto", title: "Auto", symbol: "circle.lefthalf.filled"),
                                                   .init(value: "off", title: "Off", symbol: "lightbulb.slash")]),
                                    provider: "reolink")

    init(api: ReolinkAPI) { self.api = api }

    static func choice(_ state: String) -> String? {
        switch state.lowercased() {
        case "auto": "auto"
        case "off": "off"
        default: nil
        }
    }

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        guard let state = (try await api.control("GetIrLights", ["channel": 0])["IrLights"] as? [String: Any])?["state"] as? String,
              let choice = Self.choice(state) else { throw .notSupported }
        return .choice(choice)
    }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .choice(choice) = value, Self.choice(choice) != nil else { throw .failed("auto or off") }
        _ = try await api.control("SetIrLights", ["IrLights": ["channel": 0, "state": choice == "auto" ? "Auto" : "Off"]])
    }
}

/// A switch kept as "On" or "Off" in one of the API's settings: the status light (PowerLed).
final class ReolinkStatusLight: ItemControl {
    let api: ReolinkAPI
    let item = Config.Controls.Item(id: "statusLight", title: "Status Light", symbol: "lightbulb.led", group: .light, order: 20,
                                    kind: .toggle, provider: "reolink")

    init(api: ReolinkAPI) { self.api = api }

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        guard let state = (try await api.control("GetPowerLed", ["channel": 0])["PowerLed"] as? [String: Any])?["state"] as? String
        else { throw .notSupported }
        return .on(state.lowercased() == "on")
    }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .on(on) = value else { throw .failed("on or off") }
        _ = try await api.control("SetPowerLed", ["PowerLed": ["channel": 0, "state": on ? "On" : "Off"]])
    }
}

/// One of the ISP's switches kept as 0 or 1: the picture mirrored (mirroring), or turned over (rotation), for a
/// camera mounted on a ceiling or a wall.
final class ReolinkISPSwitch: ItemControl {
    let api: ReolinkAPI
    let field: String
    let item: Config.Controls.Item

    init(api: ReolinkAPI, field: String, item: Config.Controls.Item) {
        self.api = api
        self.field = field
        self.item = item
    }

    static func mirror(_ api: ReolinkAPI) -> ReolinkISPSwitch {
        ReolinkISPSwitch(api: api, field: "mirroring", item: Config.Controls.Item(
            id: "mirror", title: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            group: .device, order: 10, kind: .toggle, provider: "reolink"))
    }

    static func flip(_ api: ReolinkAPI) -> ReolinkISPSwitch {
        ReolinkISPSwitch(api: api, field: "rotation", item: Config.Controls.Item(
            id: "flip", title: "Flip", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
            group: .device, order: 11, kind: .toggle, provider: "reolink"))
    }

    func value() async throws(ControlFailure) -> Config.Controls.Value? {
        guard let on = (try await api.control("GetIsp", ["channel": 0])["Isp"] as? [String: Any])?[field] as? Int
        else { throw .notSupported }
        return .on(on != 0)
    }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .on(on) = value else { throw .failed("on or off") }
        _ = try await api.control("SetIsp", ["Isp": ["channel": 0, field: on ? 1 : 0]])
    }
}

/// Its privacy mode, through Reolink's own protocol (the HTTP API has none): set, and read as last pushed.
final class BaichuanPrivacy: PrivacyControl {
    /// Private, a Reolink camera closes its video stream (it answers 404) and its HTTP API; turned off, both are
    /// back in about 10 s (an E1 Pro). Waited for up to this long, less when its video comes sooner.
    static let wakeTime: TimeInterval = 45

    let session: BaichuanSession
    var wakeTime: TimeInterval { Self.wakeTime }

    init(session: BaichuanSession) { self.session = session }

    func isOn() async throws(ControlFailure) -> Bool {
        if let known = session.privacyMode { return known }
        do throws(BaichuanClient.Failure) { return try session.readPrivacyMode() } catch { throw error.control }
    }

    func set(_ on: Bool) async throws(ControlFailure) {
        do throws(BaichuanClient.Failure) { _ = try session.setPrivacyMode(on) } catch { throw error.control }
    }
}

extension BaichuanClient.Failure {
    var control: ControlFailure {
        switch self {
        case .unreachable: .unreachable
        case .loginRefused: .loginRefused
        case let .status(code): .failed("the camera answered \(code)")
        case let .unexpected(what): .failed(what)
        }
    }
}

extension BaichuanSession {
    /// Connected, or turned down, or given up on after `seconds`: what it came to.
    func settled(within seconds: Double) async -> State {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            let now = state
            if now == .connected || now == .refused { return now }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return state
    }
}

extension ReolinkProvider {
    /// Its privacy mode, over Baichuan, if it answers there.
    public func privacy(_ access: CameraAccess) async -> Offer<any PrivacyControl> {
        let session = await CameraSessions.shared.baichuan(access)
        switch await session.settled(within: 8) {
        case .connected: return .yes(BaichuanPrivacy(session: session))
        case .refused: return .no
        default: return .unknown
        }
    }

    public func ptz(_ access: CameraAccess) async -> Offer<any PTZControl> {
        switch await CameraSessions.shared.reolinkAbility(access) {
        case let .yes(ability) where ability.has("ptzCtrl") || ability.has("supportPt") || ability.has("supportZoom"):
            return .yes(ReolinkPTZ(api: await CameraSessions.shared.reolink(access), ability: ability))
        case .unknown: return .unknown
        default: return .no
        }
    }

    /// Its own controls, as items, where its API has them: day and night, the speaker's volume, the IR lights,
    /// the status light, mirroring and flipping the picture (more to come: privacy mode, the siren).
    public func items(_ access: CameraAccess) async -> Offer<[any ItemControl]> {
        switch await CameraSessions.shared.reolinkAbility(access) {
        case let .yes(ability):
            let api = await CameraSessions.shared.reolink(access)
            var items: [any ItemControl] = []
            if ability.has("ispDayNight") { items.append(ReolinkNightMode(api: api)) }
            // Its speaker's volume (talking back, its alarm); the doorbell's chime is its own.
            if (try? await api.control("GetAudioCfg", ["channel": 0]))?["AudioCfg"] != nil { items.append(ReolinkVolume(api: api)) }
            // ("ledControl" is the IR lights; "powerLed" the status light.)
            if ability.has("ledControl") { items.append(ReolinkIRLights(api: api)) }
            if ability.has("powerLed") { items.append(ReolinkStatusLight(api: api)) }
            if ability.has("ispMirror") { items.append(ReolinkISPSwitch.mirror(api)) }
            if ability.has("ispFlip") { items.append(ReolinkISPSwitch.flip(api)) }
            return .yes(items)
        case .unknown: return .unknown
        case .no: return .no
        }
    }
}
