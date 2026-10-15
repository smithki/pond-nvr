// Brand-specific know-how behind one interface, so other makes of camera can be added beside Reolink's:
// each provider says what a camera is, and offers what it can (a doorbell's button, the stream addresses).
// A camera's `device.provider` says which one recognised it; its other hooks go to that one.
// Each brand's provider is in Providers/ (Reolink.swift, ONVIF.swift); a new brand is a file there and an
// entry in `CameraProviders.all`.
import Foundation
import NVRCore

public protocol CameraProvider: Sendable {
    /// Stored in `Config.Device.provider`: "reolink", "onvif".
    var id: String { get }
    /// What the camera says it is; nil if it does not answer this provider.
    func identify(host: String, username: String, password: String) async -> Config.Device?
    /// What the camera notices (motion, a doorbell's button), if this provider can see it for this camera.
    func events(host: String, username: String, password: String) -> CameraEvents?
    /// The main and sub-stream addresses for a camera at `host`, if this provider knows them.
    func streams(host: String) -> (main: String, sub: String)?
    /// The brand's own app, as advice names it ("the Reolink app"); nil to say "the camera's own app".
    var appName: String? { get }
    /// What the brand's app calls the lighter stream ("Fluent"), for advice on where to change it.
    var subStreamName: String? { get }
}

extension CameraProvider {
    public func events(host: String, username: String, password: String) -> CameraEvents? { nil }
    public func streams(host: String) -> (main: String, sub: String)? { nil }
    public var appName: String? { nil }
    public var subStreamName: String? { nil }
}

extension Config.Device {
    /// Where to change the camera's own settings, in words: its brand's app if its provider names one.
    public var appName: String { CameraProviders.provider(provider)?.appName ?? "the camera\u{2019}s own app" }
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
    public static let all: [CameraProvider] = [ReolinkProvider(), ONVIFProvider()]

    public static func provider(_ id: String?) -> CameraProvider? { all.first { $0.id == id } }
}
