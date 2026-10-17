// ONVIF's standard controls, as items (Controls.swift), each only where the camera has it: image settings
// (brightness, contrast, saturation, sharpness, within the ranges the camera gives), the speaker's volume (its
// audio output's level), the PTZ home position, preset tours, and relay outputs (a door strike, a gate).
import Foundation
import NVRCore

enum ONVIFItems {
    static let deviceIO = "http://www.onvif.org/ver10/deviceIO/wsdl"
    static let device = "http://www.onvif.org/ver10/device/wsdl"

    /// The video source the imaging service acts on (the first).
    static func source(_ device: CameraSessions.ONVIFDevice) async -> String? {
        guard let media = device.services[ONVIF.media],
              let reply = try? await device.client.call(media, "<GetVideoSources xmlns=\"\(ONVIF.media)\"/>") else { return nil }
        return reply.first("VideoSources")?.attribute("token")
    }

    // MARK: Image settings

    /// The image settings it offers, by their names in ONVIF's schema, and the item each becomes.
    static let imageSettings: [(element: String, id: String, title: String, symbol: String, order: Int)] = [
        ("Brightness", "brightness", "Brightness", "sun.max", 30),
        ("Contrast", "contrast", "Contrast", "circle.lefthalf.striped.horizontal", 31),
        ("ColorSaturation", "saturation", "Saturation", "drop", 32),
        ("Sharpness", "sharpness", "Sharpness", "triangle", 33),
    ]

    static func imaging(_ device: CameraSessions.ONVIFDevice) async -> [any ItemControl] {
        guard let service = device.services[ONVIF.imaging], let source = await source(device),
              let options = try? await device.client.call(service, "<GetOptions xmlns=\"\(ONVIF.imaging)\"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken></GetOptions>")
        else { return [] }
        return ranges(in: options).map { setting in
            ImageSetting(client: device.client, service: service, source: source, element: setting.element,
                         item: Config.Controls.Item(id: setting.id, title: setting.title, symbol: setting.symbol, group: .picture,
                                                    order: setting.order, kind: .slider(min: setting.min, max: setting.max, step: 1),
                                                    provider: "onvif"))
        }
    }

    /// The settings GetOptions gives a range for.
    static func ranges(in options: XMLNode) -> [(element: String, id: String, title: String, symbol: String, order: Int, min: Double, max: Double)] {
        imageSettings.compactMap { setting in
            guard let range = options.first(setting.element), let min = Double(range.first("Min")?.trimmed ?? ""),
                  let max = Double(range.first("Max")?.trimmed ?? ""), max > min else { return nil }
            return (setting.element, setting.id, setting.title, setting.symbol, setting.order, min, max)
        }
    }

    final class ImageSetting: ItemControl {
        let client: ONVIFClient
        let service: URL
        let source: String
        let element: String
        let item: Config.Controls.Item

        init(client: ONVIFClient, service: URL, source: String, element: String, item: Config.Controls.Item) {
            self.client = client
            self.service = service
            self.source = source
            self.element = element
            self.item = item
        }

        func value() async throws(ControlFailure) -> Config.Controls.Value? {
            let reply: XMLDocument
            do throws(ONVIFClient.Failure) {
                reply = try await client.call(service, "<GetImagingSettings xmlns=\"\(ONVIF.imaging)\"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken></GetImagingSettings>")
            } catch {
                throw error.control
            }
            guard let text = reply.first(element)?.trimmed, let number = Double(text) else { throw .notSupported }
            return .number(number)
        }

        func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
            guard case let .number(number) = value else { throw .failed("a number") }
            do throws(ONVIFClient.Failure) {
                _ = try await client.call(service, """
                <SetImagingSettings xmlns="\(ONVIF.imaging)"><VideoSourceToken>\(ONVIF.escape(source))</VideoSourceToken>\
                <ImagingSettings><\(element) xmlns="\(ONVIF.schema)">\(ONVIFPTZ.number(number))</\(element)></ImagingSettings>\
                <ForcePersistence>true</ForcePersistence></SetImagingSettings>
                """)
            } catch {
                throw error.control
            }
        }
    }

    // MARK: Speaker volume

    /// The audio output's level (the speaker's volume), from its configuration.
    struct OutputConfiguration: Equatable {
        var token: String
        var name: String
        var useCount: String
        var outputToken: String
        var sendPrimacy: String?
        var level: Double

        static func parse(_ document: XMLNode) -> OutputConfiguration? {
            guard let node = document.first("Configurations") ?? document.first("Configuration"), let token = node.attribute("token"),
                  let output = node.first("OutputToken")?.trimmed, let level = Double(node.first("OutputLevel")?.trimmed ?? "")
            else { return nil }
            return OutputConfiguration(token: token, name: node.first("Name")?.trimmed ?? token,
                                       useCount: node.first("UseCount")?.trimmed ?? "0", outputToken: output,
                                       sendPrimacy: node.first("SendPrimacy")?.trimmed, level: level)
        }

        /// As SetAudioOutputConfiguration takes it: the whole configuration, with this level.
        func xml(level: Double) -> String {
            let primacy = sendPrimacy.map { "<SendPrimacy>\(ONVIF.escape($0))</SendPrimacy>" } ?? ""
            return "<Configuration xmlns=\"\(ONVIF.schema)\" token=\"\(ONVIF.escape(token))\"><Name>\(ONVIF.escape(name))</Name>"
                + "<UseCount>\(useCount)</UseCount><OutputToken>\(ONVIF.escape(outputToken))</OutputToken>\(primacy)"
                + "<OutputLevel>\(Int(level.rounded()))</OutputLevel></Configuration>"
        }
    }

    static func speaker(_ device: CameraSessions.ONVIFDevice) async -> [any ItemControl] {
        guard let media = device.services[ONVIF.media],
              let reply = try? await device.client.call(media, "<GetAudioOutputConfigurations xmlns=\"\(ONVIF.media)\"/>"),
              let configuration = OutputConfiguration.parse(reply) else { return [] }
        // Its range, if the camera says (else 0–100); none at all if it can't be changed (a Reolink gives 50–50,
        // its volume being its own API's).
        var range = (0.0, 100.0)
        if let options = try? await device.client.call(media, "<GetAudioOutputConfigurationOptions xmlns=\"\(ONVIF.media)\"><ConfigurationToken>\(ONVIF.escape(configuration.token))</ConfigurationToken></GetAudioOutputConfigurationOptions>"),
           let levels = options.first("OutputLevelRange"), let min = Double(levels.first("Min")?.trimmed ?? ""),
           let max = Double(levels.first("Max")?.trimmed ?? "") {
            guard max > min else { return [] }
            range = (min, max)
        }
        return [SpeakerVolume(client: device.client, media: media, token: configuration.token,
                              item: Config.Controls.Item(id: "speakerVolume", title: "Speaker", symbol: "speaker.wave.2",
                                                         group: .sound, order: 10,
                                                         kind: .slider(min: range.0, max: range.1, step: 1), provider: "onvif"))]
    }

    final class SpeakerVolume: ItemControl {
        let client: ONVIFClient
        let media: URL
        let token: String
        let item: Config.Controls.Item

        init(client: ONVIFClient, media: URL, token: String, item: Config.Controls.Item) {
            self.client = client
            self.media = media
            self.token = token
            self.item = item
        }

        func configuration() async throws(ControlFailure) -> OutputConfiguration {
            let reply: XMLDocument
            do throws(ONVIFClient.Failure) {
                reply = try await client.call(media, "<GetAudioOutputConfiguration xmlns=\"\(ONVIF.media)\"><ConfigurationToken>\(ONVIF.escape(token))</ConfigurationToken></GetAudioOutputConfiguration>")
            } catch {
                throw error.control
            }
            guard let configuration = OutputConfiguration.parse(reply) else { throw .notSupported }
            return configuration
        }

        func value() async throws(ControlFailure) -> Config.Controls.Value? { .number(try await configuration().level) }

        func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
            guard case let .number(level) = value else { throw .failed("a number") }
            let configuration = try await configuration()
            do throws(ONVIFClient.Failure) {
                _ = try await client.call(media, "<SetAudioOutputConfiguration xmlns=\"\(ONVIF.media)\">\(configuration.xml(level: level))<ForcePersistence>true</ForcePersistence></SetAudioOutputConfiguration>")
            } catch {
                throw error.control
            }
        }
    }

    // MARK: Home position

    static func home(_ device: CameraSessions.ONVIFDevice) async -> [any ItemControl] {
        guard let service = device.services[ONVIF.ptz], let profile = device.profile,
              let nodes = try? await device.client.call(service, "<GetNodes xmlns=\"\(ONVIF.ptz)\"/>"),
              nodes.first("HomeSupported")?.trimmed?.lowercased() == "true" else { return [] }
        let token = "<ProfileToken>\(ONVIF.escape(profile))</ProfileToken>"
        return [
            PTZAction(client: device.client, service: service, body: "<GotoHomePosition xmlns=\"\(ONVIF.ptz)\">\(token)</GotoHomePosition>",
                      item: Config.Controls.Item(id: "home.go", title: "Home", symbol: "house", group: .move, order: 10,
                                                 kind: .action(confirm: nil), provider: "onvif")),
            PTZAction(client: device.client, service: service, body: "<SetHomePosition xmlns=\"\(ONVIF.ptz)\">\(token)</SetHomePosition>",
                      item: Config.Controls.Item(id: "home.set", title: "Set Home", symbol: "house.badge.plus", group: .move, order: 11,
                                                 kind: .action(confirm: "Make where it points now its home position?"), provider: "onvif")),
        ]
    }

    /// A PTZ request with nothing to read back: done when pressed.
    final class PTZAction: ItemControl {
        let client: ONVIFClient
        let service: URL
        let body: String
        let item: Config.Controls.Item

        init(client: ONVIFClient, service: URL, body: String, item: Config.Controls.Item) {
            self.client = client
            self.service = service
            self.body = body
            self.item = item
        }

        func perform() async throws(ControlFailure) {
            do throws(ONVIFClient.Failure) {
                _ = try await client.call(service, body)
            } catch {
                throw error.control
            }
        }
    }

    // MARK: Preset tours

    struct Tour: Equatable {
        var token: String
        var name: String
        var touring: Bool
    }

    static func tours(in document: XMLNode) -> [Tour] {
        document.all("PresetTour").compactMap { tour in
            guard let token = tour.attribute("token") else { return nil }
            let state = tour.first("Status")?.first("State")?.trimmed ?? ""
            return Tour(token: token, name: tour.first("Name")?.trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "Tour \(token)",
                        touring: state.lowercased() == "touring")
        }
    }

    static func tours(_ device: CameraSessions.ONVIFDevice) async -> [any ItemControl] {
        guard let service = device.services[ONVIF.ptz], let profile = device.profile,
              let reply = try? await device.client.call(service, "<GetPresetTours xmlns=\"\(ONVIF.ptz)\"><ProfileToken>\(ONVIF.escape(profile))</ProfileToken></GetPresetTours>")
        else { return [] }
        return tours(in: reply).enumerated().map { index, tour in
            TourControl(client: device.client, service: service, profile: profile, token: tour.token,
                        item: Config.Controls.Item(id: "tour.\(tour.token)", title: tour.name, symbol: "point.3.connected.trianglepath.dotted",
                                                   group: .move, order: 30 + index, kind: .toggle, provider: "onvif"))
        }
    }

    /// A preset tour: on while it tours.
    final class TourControl: ItemControl {
        let client: ONVIFClient
        let service: URL
        let profile: String
        let token: String
        let item: Config.Controls.Item

        init(client: ONVIFClient, service: URL, profile: String, token: String, item: Config.Controls.Item) {
            self.client = client
            self.service = service
            self.profile = profile
            self.token = token
            self.item = item
        }

        func value() async throws(ControlFailure) -> Config.Controls.Value? {
            do throws(ONVIFClient.Failure) {
                let reply = try await client.call(service, "<GetPresetTour xmlns=\"\(ONVIF.ptz)\"><ProfileToken>\(ONVIF.escape(profile))</ProfileToken><PresetTourToken>\(ONVIF.escape(token))</PresetTourToken></GetPresetTour>")
                return .on(ONVIFItems.tours(in: reply).first?.touring ?? false)
            } catch {
                throw error.control
            }
        }

        func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
            guard case let .on(on) = value else { throw .failed("on or off") }
            do throws(ONVIFClient.Failure) {
                _ = try await client.call(service, "<OperatePresetTour xmlns=\"\(ONVIF.ptz)\"><ProfileToken>\(ONVIF.escape(profile))</ProfileToken><PresetTourToken>\(ONVIF.escape(token))</PresetTourToken><Operation>\(on ? "Start" : "Stop")</Operation></OperatePresetTour>")
            } catch {
                throw error.control
            }
        }
    }

    // MARK: Relay outputs

    struct Relay: Equatable {
        var token: String
        /// Bistable: stays as set (a switch); monostable: on for a moment, then back (pressed).
        var bistable: Bool
    }

    static func relays(in document: XMLNode) -> [Relay] {
        document.all("RelayOutputs").compactMap { relay in
            guard let token = relay.attribute("token") else { return nil }
            return Relay(token: token, bistable: relay.first("Mode")?.trimmed?.lowercased() == "bistable")
        }
    }

    static func relays(_ device: CameraSessions.ONVIFDevice) async -> [any ItemControl] {
        // DeviceIO's if it has it, else the device service's (older cameras).
        let service = device.services[deviceIO] ?? device.client.deviceService
        let namespace = device.services[deviceIO] != nil ? deviceIO : Self.device
        guard let reply = try? await device.client.call(service, "<GetRelayOutputs xmlns=\"\(namespace)\"/>") else { return [] }
        let list = relays(in: reply)
        return list.enumerated().map { index, relay in
            let name = list.count == 1 ? "Relay" : "Relay \(index + 1)"
            return RelayControl(client: device.client, service: device.client.deviceService, token: relay.token,
                                item: Config.Controls.Item(id: "relay.\(relay.token)", title: name, symbol: "bolt.horizontal",
                                                           group: .device, order: 10 + index,
                                                           kind: relay.bistable ? .toggle : .action(confirm: "Switch on \(name)?"),
                                                           provider: "onvif"))
        }
    }

    /// A relay: set active or inactive (a monostable one goes back by itself).
    final class RelayControl: ItemControl {
        let client: ONVIFClient
        let service: URL
        let token: String
        let item: Config.Controls.Item

        init(client: ONVIFClient, service: URL, token: String, item: Config.Controls.Item) {
            self.client = client
            self.service = service
            self.token = token
            self.item = item
        }

        func state(_ active: Bool) async throws(ControlFailure) {
            do throws(ONVIFClient.Failure) {
                _ = try await client.call(service, "<SetRelayOutputState xmlns=\"\(ONVIFItems.device)\"><RelayOutputToken>\(ONVIF.escape(token))</RelayOutputToken><LogicalState>\(active ? "active" : "inactive")</LogicalState></SetRelayOutputState>")
            } catch {
                throw error.control
            }
        }

        /// ONVIF can't read a relay's state back: nil (the app shows what it last set).
        func set(_ value: Config.Controls.Value) async throws(ControlFailure) {
            guard case let .on(on) = value else { throw .failed("on or off") }
            try await state(on)
        }

        func perform() async throws(ControlFailure) { try await state(true) }
    }
}
