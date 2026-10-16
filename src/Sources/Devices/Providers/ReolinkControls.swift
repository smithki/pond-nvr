// Reolink's controls through its own HTTP API, where it has them: PTZ (PtzCtrl's directions and zoom, and its
// presets) and day/night (the ISP's dayNight). What a camera can do is in GetAbility, asked once. Talking back
// isn't in this API (Reolink's apps use its proprietary protocol for it), so that is left to ONVIF.
import Foundation
import NVRCore

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
final class ReolinkNightMode: NightModeControl {
    let api: ReolinkAPI
    let abilities = Config.Controls.NightMode(provider: "reolink", choices: NightMode.allCases.map(\.rawValue))

    init(api: ReolinkAPI) { self.api = api }

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

extension ReolinkProvider {
    public func ptz(_ access: CameraAccess) async -> Offer<any PTZControl> {
        switch await CameraSessions.shared.reolinkAbility(access) {
        case let .yes(ability) where ability.has("ptzCtrl") || ability.has("supportPt") || ability.has("supportZoom"):
            return .yes(ReolinkPTZ(api: await CameraSessions.shared.reolink(access), ability: ability))
        case .unknown: return .unknown
        default: return .no
        }
    }

    public func nightMode(_ access: CameraAccess) async -> Offer<any NightModeControl> {
        switch await CameraSessions.shared.reolinkAbility(access) {
        case let .yes(ability) where ability.has("ispDayNight"):
            return .yes(ReolinkNightMode(api: await CameraSessions.shared.reolink(access)))
        case .unknown: return .unknown
        default: return .no
        }
    }
}
