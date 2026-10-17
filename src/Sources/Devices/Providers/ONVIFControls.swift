// ONVIF's controls: PTZ (continuous moves and presets, on the main stream's profile) and night mode (the
// imaging service's IR-cut filter). Talking back is in ONVIFTalk.swift.
import Foundation
import NVRCore

extension ONVIF {
    static let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
    static let imaging = "http://www.onvif.org/ver20/imaging/wsdl"
    static let schema = "http://www.onvif.org/ver10/schema"
}

extension ONVIFClient.Failure {
    /// As a control's failure: a camera that says it doesn't do it, a refused login, no answer, or else.
    var control: ControlFailure {
        let text = description.lowercased()
        if ["notsupported", "not support", "actionnotsupported", "no such service", "noptznode", "noprofile"]
            .contains(where: text.contains) { return .notSupported }
        if loginRefused { return .loginRefused }
        if text.hasPrefix("no answer") { return .unreachable }
        return .failed(description)
    }
}

/// The camera's PTZ node, as GetNodes describes it: what it moves, and how many presets it keeps.
struct ONVIFPTZNode: Equatable {
    var panTilt: Bool
    var zoom: Bool
    var presets: Int

    static func parse(_ document: XMLNode) -> ONVIFPTZNode? {
        guard let node = document.first("PTZNode"), let spaces = node.first("SupportedPTZSpaces") else { return nil }
        return ONVIFPTZNode(panTilt: spaces.first("ContinuousPanTiltVelocitySpace") != nil,
                            zoom: spaces.first("ContinuousZoomVelocitySpace") != nil,
                            presets: Int(node.first("MaximumNumberOfPresets")?.trimmed ?? "") ?? 0)
    }
}

final class ONVIFPTZ: PTZControl {
    let client: ONVIFClient
    let service: URL
    let profile: String
    let abilities: Config.Controls.PTZ

    init(client: ONVIFClient, service: URL, profile: String, node: ONVIFPTZNode) {
        self.client = client
        self.service = service
        self.profile = profile
        abilities = Config.Controls.PTZ(provider: "onvif", panTilt: node.panTilt, zoom: node.zoom, presets: node.presets)
    }

    /// The camera's PTZ, if it has a node that moves.
    static func make(_ device: CameraSessions.ONVIFDevice) async -> ONVIFPTZ? {
        guard let service = device.services[ONVIF.ptz], let profile = device.profile,
              let reply = try? await device.client.call(service, "<GetNodes xmlns=\"\(ONVIF.ptz)\"/>"),
              let node = ONVIFPTZNode.parse(reply), node.panTilt || node.zoom else { return nil }
        return ONVIFPTZ(client: device.client, service: service, profile: profile, node: node)
    }

    private func call(_ body: String) async throws(ControlFailure) -> XMLDocument {
        do throws(ONVIFClient.Failure) {
            return try await client.call(service, body)
        } catch {
            throw error.control
        }
    }

    var token: String { "<ProfileToken>\(ONVIF.escape(profile))</ProfileToken>" }

    func move(_ velocity: PTZVelocity) async throws(ControlFailure) {
        if velocity.isStill { return try await stop() }
        var parts = ""
        if abilities.panTilt {
            parts += "<PanTilt xmlns=\"\(ONVIF.schema)\" x=\"\(Self.number(velocity.pan))\" y=\"\(Self.number(velocity.tilt))\"/>"
        }
        if abilities.zoom { parts += "<Zoom xmlns=\"\(ONVIF.schema)\" x=\"\(Self.number(velocity.zoom))\"/>" }
        _ = try await call("<ContinuousMove xmlns=\"\(ONVIF.ptz)\">\(token)<Velocity>\(parts)</Velocity></ContinuousMove>")
    }

    func stop() async throws(ControlFailure) {
        _ = try await call("<Stop xmlns=\"\(ONVIF.ptz)\">\(token)<PanTilt>\(abilities.panTilt)</PanTilt><Zoom>\(abilities.zoom)</Zoom></Stop>")
    }

    func presets() async throws(ControlFailure) -> [PTZPreset] {
        Self.presets(in: try await call("<GetPresets xmlns=\"\(ONVIF.ptz)\">\(token)</GetPresets>"))
    }

    static func presets(in document: XMLNode) -> [PTZPreset] {
        document.all("Preset").compactMap { preset in
            guard let id = preset.attribute("token") else { return nil }
            return PTZPreset(id: id, name: preset.first("Name")?.trimmed ?? id)
        }
    }

    func goTo(_ preset: String) async throws(ControlFailure) {
        _ = try await call("<GotoPreset xmlns=\"\(ONVIF.ptz)\">\(token)<PresetToken>\(ONVIF.escape(preset))</PresetToken></GotoPreset>")
    }

    func savePreset(_ name: String, replacing: String?) async throws(ControlFailure) -> PTZPreset {
        let existing = replacing.map { "<PresetToken>\(ONVIF.escape($0))</PresetToken>" } ?? ""
        let reply = try await call("<SetPreset xmlns=\"\(ONVIF.ptz)\">\(token)<PresetName>\(ONVIF.escape(name))</PresetName>\(existing)</SetPreset>")
        guard let id = reply.first("PresetToken")?.trimmed ?? replacing else { throw .failed("no preset in the answer") }
        return PTZPreset(id: id, name: name)
    }

    func removePreset(_ preset: String) async throws(ControlFailure) {
        _ = try await call("<RemovePreset xmlns=\"\(ONVIF.ptz)\">\(token)<PresetToken>\(ONVIF.escape(preset))</PresetToken></RemovePreset>")
    }

    /// A speed as ONVIF writes it (no exponent).
    static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}

/// Night mode through the imaging service's IR-cut filter: AUTO the camera's choice, ON (filter in) day,
/// OFF (filter out, IR on) night.
final class ONVIFNightMode: ItemControl {
    let client: ONVIFClient
    let service: URL
    let source: String
    let item: Config.Controls.Item
    let choices: [NightMode]

    init(client: ONVIFClient, service: URL, source: String, choices: [NightMode]) {
        self.client = client
        self.service = service
        self.source = source
        self.choices = choices
        item = NightMode.item(choices, provider: "onvif")
    }

    func value() async throws(ControlFailure) -> Config.Controls.Value? { .choice(try await nightMode().rawValue) }

    func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
        guard case let .choice(text) = value, let mode = NightMode(rawValue: text) else { throw .failed("auto, day or night") }
        try await setNightMode(mode)
    }

    static func mode(_ filter: String) -> NightMode? {
        switch filter.uppercased() {
        case "AUTO": .auto
        case "ON": .day
        case "OFF": .night
        default: nil
        }
    }

    static func filter(_ mode: NightMode) -> String {
        switch mode {
        case .auto: "AUTO"
        case .day: "ON"
        case .night: "OFF"
        }
    }

    /// The choices in GetOptions' IR-cut filter modes, in Pond's order.
    static func choices(in document: XMLNode) -> [NightMode] {
        let modes = Set(document.all("IrCutFilterModes").compactMap { $0.trimmed.flatMap(mode) })
        return NightMode.allCases.filter(modes.contains)
    }

    /// The camera's night mode, if it offers more than one choice.
    static func make(_ device: CameraSessions.ONVIFDevice) async -> ONVIFNightMode? {
        guard let service = device.services[ONVIF.imaging], let media = device.services[ONVIF.media],
              let sources = try? await device.client.call(media, "<GetVideoSources xmlns=\"\(ONVIF.media)\"/>"),
              let source = sources.first("VideoSources")?.attribute("token"),
              let options = try? await device.client.call(service, "<GetOptions xmlns=\"\(ONVIF.imaging)\"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken></GetOptions>")
        else { return nil }
        let choices = choices(in: options)
        guard choices.count > 1 else { return nil }
        return ONVIFNightMode(client: device.client, service: service, source: source, choices: choices)
    }

    func nightMode() async throws(ControlFailure) -> NightMode {
        let reply: XMLDocument
        do throws(ONVIFClient.Failure) {
            reply = try await client.call(service, "<GetImagingSettings xmlns=\"\(ONVIF.imaging)\"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken></GetImagingSettings>")
        } catch {
            throw error.control
        }
        guard let mode = reply.first("IrCutFilter")?.trimmed.flatMap(Self.mode) else { throw .notSupported }
        return mode
    }

    func setNightMode(_ mode: NightMode) async throws(ControlFailure) {
        guard choices.contains(mode) else { throw .notSupported }
        do throws(ONVIFClient.Failure) {
            _ = try await client.call(service, """
            <SetImagingSettings xmlns="\(ONVIF.imaging)"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken>\
            <ImagingSettings><IrCutFilter xmlns="\(ONVIF.schema)">\(Self.filter(mode))</IrCutFilter></ImagingSettings>\
            <ForcePersistence>true</ForcePersistence></SetImagingSettings>
            """)
        } catch {
            throw error.control
        }
    }
}

extension ONVIFProvider {
    public func ptz(_ access: CameraAccess) async -> Offer<any PTZControl> {
        guard let device = await CameraSessions.shared.onvif(access) else { return .unknown }
        return await ONVIFPTZ.make(device).map { .yes($0) } ?? .no
    }

    /// Its standard controls, as items: day and night, image settings, speaker volume, home position, preset
    /// tours, relay outputs (ONVIFItems.swift); each only if the camera has it.
    public func items(_ access: CameraAccess) async -> Offer<[any ItemControl]> {
        guard let device = await CameraSessions.shared.onvif(access) else { return .unknown }
        var items: [any ItemControl] = []
        if let night = await ONVIFNightMode.make(device) { items.append(night) }
        items += await ONVIFItems.imaging(device)
        items += await ONVIFItems.speaker(device)
        items += await ONVIFItems.home(device)
        items += await ONVIFItems.tours(device)
        items += await ONVIFItems.relays(device)
        items.append(ONVIFItems.restart(device))
        return .yes(items)
    }
}
