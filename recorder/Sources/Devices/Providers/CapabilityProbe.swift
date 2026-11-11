// What a camera says it can do, asked every way Pond knows and written out as it answers, for
// `pond camera abilities ID`: ONVIF's services and their capabilities, its PTZ (nodes, spaces, presets),
// audio output (for talking back), and imaging (day/night); Reolink's GetAbility and the commands its PTZ,
// zoom and audio use. Read-only: nothing is moved or changed.
import Foundation

public enum CapabilityProbe {
    /// Each answer as a heading and the reply (XML or JSON, compacted), told as they come.
    public static func onvif(host: String, username: String, password: String,
                             tell: @escaping @Sendable (String) -> Void) async {
        guard let client = await ONVIFClient.connect(host: host, username: username, password: password) else {
            tell("✗ ONVIF: nothing answered")
            return
        }
        tell("✓ ONVIF at \(client.deviceService.absoluteString)")
        func ask(_ title: String, _ service: URL?, _ body: String) async -> XMLDocument? {
            guard let service else { tell("· \(title): no such service"); return nil }
            do throws(ONVIFClient.Failure) {
                let reply = try await client.call(service, body)
                tell("✓ \(title):\n\(compact(reply))")
                return reply
            } catch {
                tell("✗ \(title): \(error.description)")
                return nil
            }
        }
        let device = "http://www.onvif.org/ver10/device/wsdl"
        _ = await ask("GetServices (with capabilities)", client.deviceService,
                      "<GetServices xmlns=\"\(device)\"><IncludeCapability>true</IncludeCapability></GetServices>")
        guard let services = try? await client.services() else { return }

        let media = services[ONVIF.media]
        let profiles = (try? await client.profiles(media: media ?? client.deviceService)) ?? []
        let profile = ONVIFClient.choose(profiles)?.main.token ?? profiles.first?.token ?? ""
        tell("· profiles: \(profiles.map(\.token).joined(separator: ", ")); asking about \(profile)")
        if let media {
            let reply = try? await client.call(media, "<GetProfiles xmlns=\"\(ONVIF.media)\"/>")
            if let reply {
                for p in reply.all("Profiles") where p.attribute("token") == profile {
                    tell("✓ profile \(profile):\n\(compact(p))")
                }
            }
        }

        // PTZ.
        let ptzNS = "http://www.onvif.org/ver20/ptz/wsdl"
        let ptz = services[ptzNS]
        _ = await ask("PTZ GetNodes", ptz, "<GetNodes xmlns=\"\(ptzNS)\"/>")
        _ = await ask("PTZ GetConfigurations", ptz, "<GetConfigurations xmlns=\"\(ptzNS)\"/>")
        _ = await ask("PTZ GetPresets", ptz, "<GetPresets xmlns=\"\(ptzNS)\"><ProfileToken>\(profile)</ProfileToken></GetPresets>")
        _ = await ask("PTZ GetStatus", ptz, "<GetStatus xmlns=\"\(ptzNS)\"><ProfileToken>\(profile)</ProfileToken></GetStatus>")

        // Audio out (talking back).
        _ = await ask("Media GetAudioOutputs", media, "<GetAudioOutputs xmlns=\"\(ONVIF.media)\"/>")
        _ = await ask("Media GetAudioOutputConfigurations", media, "<GetAudioOutputConfigurations xmlns=\"\(ONVIF.media)\"/>")
        _ = await ask("Media GetAudioDecoderConfigurations", media, "<GetAudioDecoderConfigurations xmlns=\"\(ONVIF.media)\"/>")
        _ = await ask("Media GetCompatibleAudioOutputConfigurations", media,
                      "<GetCompatibleAudioOutputConfigurations xmlns=\"\(ONVIF.media)\"><ProfileToken>\(profile)</ProfileToken></GetCompatibleAudioOutputConfigurations>")
        let media2 = services[ONVIF.media2]
        _ = await ask("Media2 GetAudioOutputConfigurations", media2, "<GetAudioOutputConfigurations xmlns=\"\(ONVIF.media2)\"/>")
        _ = await ask("Media2 GetAudioDecoderConfigurations", media2, "<GetAudioDecoderConfigurations xmlns=\"\(ONVIF.media2)\"/>")
        let ioNS = "http://www.onvif.org/ver10/deviceIO/wsdl"
        _ = await ask("DeviceIO GetAudioOutputs", services[ioNS], "<GetAudioOutputs xmlns=\"\(ioNS)\"/>")

        // Imaging (day/night, IR).
        let sources = await ask("Media GetVideoSources", media, "<GetVideoSources xmlns=\"\(ONVIF.media)\"/>")
        let source = sources?.first("VideoSources")?.attribute("token") ?? ""
        let imagingNS = "http://www.onvif.org/ver20/imaging/wsdl"
        let imaging = services[imagingNS]
        _ = await ask("Imaging GetImagingSettings", imaging,
                      "<GetImagingSettings xmlns=\"\(imagingNS)\"><VideoSourceToken>\(source)</VideoSourceToken></GetImagingSettings>")
        _ = await ask("Imaging GetOptions", imaging, "<GetOptions xmlns=\"\(imagingNS)\"><VideoSourceToken>\(source)</VideoSourceToken></GetOptions>")
    }

    /// Reolink's own API: GetAbility in full, then whether the commands for PTZ, zoom and audio answer.
    public static func reolink(host: String, username: String, password: String,
                               tell: @escaping @Sendable (String) -> Void) async {
        let api = ReolinkAPI(host: host, username: username, password: password)
        do throws(ReolinkAPI.Failure) {
            let ability = try await api.command("GetAbility", param: ["User": ["userName": username]])
            tell("✓ Reolink GetAbility:\n\(json(ability))")
        } catch {
            tell("✗ Reolink GetAbility: \(error)")
            return
        }
        for (cmd, param) in [("GetPtzPreset", ["channel": 0]), ("GetPtzPatrol", ["channel": 0]), ("GetPtzGuard", ["channel": 0]),
                             ("GetPtzCheckState", ["channel": 0]), ("GetZoomFocus", ["channel": 0]), ("GetAutoFocus", ["channel": 0]),
                             ("GetAudioCfg", ["channel": 0]), ("GetIrLights", ["channel": 0]), ("GetIsp", ["channel": 0]),
                             ("GetWhiteLed", ["channel": 0]), ("GetPtzSerial", ["channel": 0]), ("GetPtzTattern", ["channel": 0])] as [(String, [String: Any])] {
            do throws(ReolinkAPI.Failure) {
                let value = try await api.command(cmd, param: param)
                tell("✓ Reolink \(cmd):\n\(json(value))")
            } catch {
                tell("✗ Reolink \(cmd): \(error)")
            }
        }
        // Logged out before returning (a camera allows only a few logins at once).
        await api.logout()
    }

    /// One request to one of the camera's ONVIF services (by the last parts of its namespace: "media",
    /// "ver20/media", "imaging", "ptz", "device"), its reply as written, for working out what a camera wants.
    public static func call(host: String, username: String, password: String, service: String, body: String) async -> String {
        guard let client = await ONVIFClient.connect(host: host, username: username, password: password) else { return "✗ no ONVIF" }
        let services = (try? await client.services()) ?? [:]
        let url = service == "device" ? client.deviceService
            : services.first { $0.key.hasSuffix("/\(service)/wsdl") || $0.key.hasSuffix("\(service)/wsdl") }?.value
        guard let url else { return "✗ no service \(service): \(services.keys.sorted().joined(separator: ", "))" }
        do throws(ONVIFClient.Failure) {
            return compact(try await client.call(url, body))
        } catch {
            return "✗ \(error.description)"
        }
    }

    static func compact(_ node: XMLNode) -> String {
        let body = (node as? XMLDocument)?.first("Body")?.children?.first ?? node
        let text = body.xmlString
        // Without namespace prefixes and declarations, for reading.
        let stripped = text
            .replacingOccurrences(of: #" xmlns(:[A-Za-z0-9_]+)?="[^"]*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<(/?)[A-Za-z0-9_]+:"#, with: "<$1", options: .regularExpression)
        return "    " + stripped
    }

    static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "    ?" }
        return "    " + String(decoding: data, as: UTF8.self)
    }
}
