// Connections to cameras, kept and shared: one ONVIF client per camera (found once: its port, its clock, its
// services and media profiles) and one Reolink login per camera, used by every control, so a move of the
// picture doesn't log in first. A connection that fails is dropped and made again next time.
import Foundation

public actor CameraSessions {
    public static let shared = CameraSessions()

    /// An ONVIF camera, with what was learned on connecting.
    public struct ONVIFDevice: Sendable {
        public let client: ONVIFClient
        public let services: [String: URL]
        public let profiles: [ONVIFClient.Profile]

        /// The profile controls act on: the main stream's (PTZ, audio out are per profile).
        public var profile: String? { ONVIFClient.choose(profiles)?.main.token ?? profiles.first?.token }
    }

    private var onvif: [CameraAccess: Task<ONVIFDevice?, Never>] = [:]
    private var reolink: [CameraAccess: ReolinkAPI] = [:]
    /// What each Reolink camera said it can do (ReolinkControls).
    var reolinkAbilities: [CameraAccess: ReolinkAbility] = [:]

    /// The camera over ONVIF, connected once; nil if it doesn't answer ONVIF.
    public func onvif(_ access: CameraAccess) async -> ONVIFDevice? {
        if let pending = onvif[access] {
            if let device = await pending.value { return device }
        }
        let task = Task<ONVIFDevice?, Never> {
            guard let client = await ONVIFClient.connect(host: access.host, username: access.username, password: access.password),
                  let services = try? await client.services() else { return nil }
            let profiles = await services[ONVIF.media].asyncMap { try? await client.profiles(media: $0) } ?? []
            return ONVIFDevice(client: client, services: services, profiles: profiles ?? [])
        }
        onvif[access] = task
        let device = await task.value
        if device == nil { onvif[access] = nil }
        return device
    }

    /// The camera's Reolink API, logged in on first use and kept.
    public func reolink(_ access: CameraAccess) -> ReolinkAPI {
        if let api = reolink[access] { return api }
        let api = ReolinkAPI(host: access.host, username: access.username, password: access.password)
        reolink[access] = api
        return api
    }

    /// Logs out of every camera (when the service stops: a login left open holds one of the few a Reolink
    /// camera allows until it lapses, about an hour later).
    public func forgetAll() async {
        for access in Set(reolink.keys).union(onvif.keys) { await forget(access) }
    }

    /// Forgets a camera's connections (its password or address changed, or it was removed).
    public func forget(_ access: CameraAccess) async {
        onvif[access] = nil
        reolinkAbilities[access] = nil
        if let api = reolink.removeValue(forKey: access) { await api.logout() }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
