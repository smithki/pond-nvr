// Brand-specific know-how behind one interface, so other makes of camera can be added beside Reolink's:
// each provider says what a camera is, and offers what it can (a doorbell's button, the stream addresses,
// and controls: PTZ, talking back, and the rest as declared items: night mode, image settings, volume…). A camera's `device.provider` says which one it was chosen to
// be talked to through; each control is then served by the first provider in order (that one, the others
// that fit the camera, ONVIF last) that answers for it (see Controls.swift), so a make's own API is used
// where it does something and ONVIF fills in the rest.
// Each provider is in Providers/ (Reolink.swift, ONVIF.swift); a new one (another make's API, a proprietary
// protocol for one feature) is a file there and an entry in `CameraProviders.all`.
import Foundation
import NVRCore

public protocol CameraProvider: Sendable {
    /// Stored in `Config.Device.provider`: "reolink", "onvif".
    var id: String { get }
    /// As people read it: "Reolink", "ONVIF".
    var name: String { get }
    /// The make whose cameras it is for ("Reolink"); nil for ONVIF, which is for any.
    var maker: String? { get }
    /// What the camera says it is; nil if it does not answer this provider.
    func identify(host: String, username: String, password: String) async -> Config.Device?
    /// What the camera notices (motion, a doorbell's button), if this provider can see it for this camera.
    func events(host: String, username: String, password: String) -> CameraEvents?
    /// The main and sub-stream addresses for a camera at `host`, if this provider knows them without asking.
    func streams(host: String) -> (main: String, sub: String)?
    /// The main and sub-stream addresses, asked of the camera (logging in); nil if it isn't this provider's.
    func findStreams(host: String, username: String, password: String) async -> (main: String, sub: String)?
    /// The brand's own app, as advice names it ("the Reolink app"); nil to say "the camera's own app".
    var appName: String? { get }
    /// What the brand's app calls the lighter stream ("Fluent"), for advice on where to change it.
    var subStreamName: String? { get }

    /// The camera's controls through this provider: offered if it can do them for this camera (asked of the
    /// camera, once; the connection is shared, see CameraSessions), not if it can't, or unknown if the camera
    /// couldn't be asked just now (it's asked again later, so a moment's trouble doesn't pass it over).
    func ptz(_ access: CameraAccess) async -> Offer<any PTZControl>
    /// Its other controls for this camera, as declared items (Controls.swift): the dock draws them by group.
    func items(_ access: CameraAccess) async -> Offer<[any ItemControl]>
    func talk(_ access: CameraAccess) async -> Offer<any TalkControl>
    /// The camera's own privacy mode, if this provider can switch it (Pond's own privacy needs none).
    func privacy(_ access: CameraAccess) async -> Offer<any PrivacyControl>
}

extension CameraProvider {
    public func events(host: String, username: String, password: String) -> CameraEvents? { nil }
    public func streams(host: String) -> (main: String, sub: String)? { nil }
    /// By default: the known addresses, for a camera this provider recognises.
    public func findStreams(host: String, username: String, password: String) async -> (main: String, sub: String)? {
        guard let known = streams(host: host), await identify(host: host, username: username, password: password) != nil
        else { return nil }
        return known
    }
    public var appName: String? { nil }
    public var subStreamName: String? { nil }
    public var maker: String? { nil }
    public func ptz(_ access: CameraAccess) async -> Offer<any PTZControl> { .no }
    public func items(_ access: CameraAccess) async -> Offer<[any ItemControl]> { .no }
    public func talk(_ access: CameraAccess) async -> Offer<any TalkControl> { .no }
    public func privacy(_ access: CameraAccess) async -> Offer<any PrivacyControl> { .no }
}

extension Config.Device {
    /// Where to change the camera's own settings, in words: its brand's app if its provider names one.
    public var appName: String {
        CameraProviders.provider(provider)?.appName ?? CameraProviders.choices(for: self).compactMap(\.appName).first
            ?? "the camera\u{2019}s own app"
    }
}

/// What a camera notices, as it happens, until stopped: one watcher per camera, so it is asked once.
public protocol CameraEvents: AnyObject, Sendable {
    /// `motion` with each change (the camera's own detection: movement, a person, a vehicle, an animal),
    /// `pressed` for each press of a doorbell's button, and `state` whether it can be watched at all (and
    /// why not), for the app to show.
    func start(motion: @escaping @Sendable (Bool) -> Void, pressed: @escaping @Sendable () -> Void,
               state: @escaping @Sendable (DoorbellButtonState) -> Void)
    func stop()
}

public enum DoorbellButtonState: Equatable, Sendable {
    case watching
    /// The camera does not report presses in a way this provider can read (its firmware, or the model).
    case notSupported
    /// The camera could not be reached or turned down the login; it is tried again.
    case unreachable
    case loginRefused
}

public enum CameraProviders {
    /// In the order they are tried: the brand-specific first, ONVIF last as the general case.
    public static var all: [CameraProvider] { extra + builtIn }
    static let builtIn: [CameraProvider] = [ReolinkProvider(), ONVIFProvider()]
    /// Others, first: demo mode's made-up make, in a demo's service.
    nonisolated(unsafe) public static var extra: [CameraProvider] = []

    public static func provider(_ id: String?) -> CameraProvider? { all.first { $0.id == id } }

    /// The ways Pond can talk to this camera: its make's own provider (when Pond has one for it), then ONVIF.
    /// One way only (ONVIF) when Pond knows nothing of the make; none before the camera has said what it is.
    public static func choices(for device: Config.Device?) -> [CameraProvider] {
        guard let device else { return [] }
        let own = all.filter { provider in
            provider.id == device.provider && provider.maker != nil
                || provider.maker.map { device.manufacturer.localizedCaseInsensitiveContains($0) } == true
        }
        return own + all.filter { $0.maker == nil }
    }

    /// The providers a camera's controls are asked of, in order: the one it was chosen to be talked to
    /// through, then the others that fit it (its make's, ONVIF). None for a camera that is video only.
    public static func order(for device: Config.Device?) -> [CameraProvider] {
        guard let device else { return all.filter { $0.maker == nil } }
        if device.isVideoOnly { return [] }
        let fitting = choices(for: device)
        let chosen = fitting.filter { $0.id == device.provider }
        return chosen + fitting.filter { $0.id != device.provider }
    }

    /// A camera's stream addresses, from the first provider that can say: its brand's known addresses, else
    /// what it describes over ONVIF. Nil if none can (the addresses are then typed in).
    public static func findStreams(host: String, username: String, password: String) async
        -> (main: String, sub: String, provider: String)? {
        for provider in all {
            if let found = await provider.findStreams(host: host, username: username, password: password) {
                return (found.main, found.sub, provider.id)
            }
        }
        return nil
    }
}
