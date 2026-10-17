// What can be done to a camera beyond reading its video: moving it (PTZ), its night mode, and talking through
// its speaker. Each is a feature of its own, and each is served by whichever provider can for this camera:
// its make's own (Reolink's API) first, the general one (ONVIF) after, so one camera can move through its
// maker's API and talk over ONVIF. A provider offers a feature by answering for it (see CameraProvider); the
// resolver (CameraControls) asks them in order, keeps the first that answers, and moves on to the next when
// one turns out not to work at all for this camera. Adding a way (another make's API, a proprietary protocol
// for talking) is a provider that answers for the features it does.
import Foundation
import NVRCore

/// How to reach a camera: what every provider needs to log in.
public struct CameraAccess: Hashable, Sendable {
    public var host: String
    public var username: String
    public var password: String
    /// Its main stream's address (talking back goes over the same RTSP).
    public var mainStream: String?

    public init(host: String, username: String, password: String, mainStream: String? = nil) {
        self.host = host
        self.username = username
        self.password = password
        self.mainStream = mainStream
    }
}

/// Why a control did not work.
public enum ControlFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// This way of talking to the camera can't do it (another may).
    case notSupported
    /// The camera did not answer; try again later.
    case unreachable
    /// It turned the login down.
    case loginRefused
    /// It has as many logins open as it allows; they lapse after a while (Reolink's allow only a few).
    case busy
    /// It answered, but refused or failed; the words are the camera's or the protocol's.
    case failed(String)

    public var description: String {
        switch self {
        case .notSupported: "the camera can\u{2019}t do that this way"
        case .unreachable: "the camera didn\u{2019}t answer"
        case .loginRefused: "the camera turned down the login"
        case .busy: "the camera has too many logins open; try again in a few minutes"
        case let .failed(why): why
        }
    }
}

// MARK: - PTZ

/// A move at a speed, until stopped: each of pan (right +), tilt (up +) and zoom (in +), from −1 to 1.
public struct PTZVelocity: Equatable, Sendable, Codable {
    public var pan: Double
    public var tilt: Double
    public var zoom: Double

    public init(pan: Double = 0, tilt: Double = 0, zoom: Double = 0) {
        self.pan = max(-1, min(1, pan))
        self.tilt = max(-1, min(1, tilt))
        self.zoom = max(-1, min(1, zoom))
    }

    public var isStill: Bool { pan == 0 && tilt == 0 && zoom == 0 }
}

/// A position the camera keeps, by its own id for it.
public struct PTZPreset: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol PTZControl: Sendable {
    /// What it can do (pan and tilt, zoom, how many presets), and through which provider.
    var abilities: Config.Controls.PTZ { get }
    /// Moves at this speed until `stop` (or another move).
    func move(_ velocity: PTZVelocity) async throws(ControlFailure)
    func stop() async throws(ControlFailure)
    func presets() async throws(ControlFailure) -> [PTZPreset]
    func goTo(_ preset: String) async throws(ControlFailure)
    /// Keeps where it points now under `name`, as `replacing` if given (else a free place); returns it.
    func savePreset(_ name: String, replacing: String?) async throws(ControlFailure) -> PTZPreset
    func removePreset(_ preset: String) async throws(ControlFailure)
}

// MARK: - Night mode

extension NightMode {
    /// Day and night as an item: first under Picture, whichever provider serves it.
    static func item(_ choices: [NightMode], provider: String) -> Config.Controls.Item {
        Config.Controls.Item(id: "dayNight", title: "Day & Night", symbol: "circle.lefthalf.filled", group: .picture, order: 10,
                             kind: .choice(choices.map(\.choice)), provider: provider)
    }

    var choice: Config.Controls.Item.Choice {
        switch self {
        case .auto: .init(value: rawValue, title: "Auto", symbol: "circle.lefthalf.filled")
        case .day: .init(value: rawValue, title: "Day", symbol: "sun.max.fill")
        case .night: .init(value: rawValue, title: "Night", symbol: "moon.stars.fill")
        }
    }
}

public enum NightMode: String, Equatable, Sendable, Codable, CaseIterable {
    /// The camera chooses by the light.
    case auto
    /// Colour, IR off.
    case day
    /// Black and white, IR on.
    case night
}

/// One of a camera's controls, declared (what it is, where it goes, its kind) and worked: read, set, or done.
public protocol ItemControl: Sendable {
    var item: Config.Controls.Item { get }
    /// Its value now; nil for an action.
    func value() async throws(ControlFailure) -> Config.Controls.Value?
    func set(_ value: Config.Controls.Value) async throws(ControlFailure)
    func perform() async throws(ControlFailure)
}

extension ItemControl {
    public func value() async throws(ControlFailure) -> Config.Controls.Value? { nil }
    public func set(_ value: Config.Controls.Value) async throws(ControlFailure) { throw .notSupported }
    public func perform() async throws(ControlFailure) { throw .notSupported }
}

// MARK: - Privacy

/// The camera's own privacy mode: it stops sending video and sound itself (Pond's privacy, PrivacyState, works
/// for every camera; this is the camera following it, where its provider can switch it).
public protocol PrivacyControl: Sendable {
    func isOn() async throws(ControlFailure) -> Bool
    func set(_ on: Bool) async throws(ControlFailure)
}

// MARK: - Talking back

public protocol TalkControl: Sendable {
    var abilities: Config.Controls.Talk { get }
    /// A connection to the camera's speaker, open until closed.
    func open() async throws(ControlFailure) -> TalkSession
}

/// Sound on its way to the camera's speaker: 16-bit mono PCM at `sampleRate`, as it's captured.
public protocol TalkSession: AnyObject, Sendable {
    var sampleRate: Double { get }
    func send(_ samples: [Int16]) throws(ControlFailure)
    func close()
}

// MARK: - Choosing a provider for each

/// A provider's answer for one control on one camera.
public enum Offer<T> {
    case yes(T)
    /// It can't (the camera hasn't it, or not this way).
    case no
    /// The camera couldn't be asked just now (no answer, or too many logins open).
    case unknown

    var value: T? { if case let .yes(v) = self { v } else { nil } }
}

extension Offer: Sendable where T: Sendable {}

/// A camera's controls, each served by the first provider (in order of preference) that can for it. Worked
/// out once, as asked for, and kept; a provider that turns out not to support one (it says so when used) is
/// passed over for the next. Connections are each provider's own and kept (CameraSessions), so nothing is
/// logged into twice.
public actor CameraControls {
    public let access: CameraAccess
    /// The providers to try, the preferred first.
    let providers: [CameraProvider]

    private var ptzChoice: Choice<any PTZControl> = .unknown
    private var talkChoice: Choice<any TalkControl> = .unknown
    private var privacyChoice: Choice<any PrivacyControl> = .unknown
    /// Each item, by id, from the first provider that declares it; nil until asked. `itemsRetry`: a provider
    /// couldn't be asked, so they're asked again after then.
    private var itemChoice: [String: (control: any ItemControl, index: Int)]?
    private var itemsRetry: Date?

    enum Choice<T> {
        case unknown
        /// This one, at this place in `providers` (those before it were passed over). `until`: a provider
        /// before it couldn't be asked, so this stands in until then, when they're asked again.
        case chosen(T, index: Int, until: Date?)
        /// None can; `until` as above.
        case none(until: Date?)
    }

    /// How long a stand-in is used before a preferred provider that couldn't be asked is asked again.
    static let retry: TimeInterval = 60

    public init(access: CameraAccess, providers: [CameraProvider]) {
        self.access = access
        self.providers = providers
    }

    /// For a camera from its settings: its chosen provider first, then the others that fit it, ONVIF last;
    /// none for a camera chosen to be video only.
    public init(access: CameraAccess, device: Config.Device?) {
        self.init(access: access, providers: CameraProviders.order(for: device))
    }

    public func ptz() async -> (any PTZControl)? {
        ptzChoice = await resolve(ptzChoice) { await $0.ptz(access) }
        if case let .chosen(control, _, _) = ptzChoice { return control }
        return nil
    }


    public func talk() async -> (any TalkControl)? {
        talkChoice = await resolve(talkChoice) { await $0.talk(access) }
        if case let .chosen(control, _, _) = talkChoice { return control }
        return nil
    }

    public func privacy() async -> (any PrivacyControl)? {
        privacyChoice = await resolve(privacyChoice) { await $0.privacy(access) }
        if case let .chosen(control, _, _) = privacyChoice { return control }
        return nil
    }

    /// Does `work` with the camera's own privacy mode; if that provider says it can't, with the next one.
    public func withPrivacy<T: Sendable>(_ work: (any PrivacyControl) async throws(ControlFailure) -> T) async throws(ControlFailure) -> T {
        while true {
            guard let control = await privacy() else { throw .notSupported }
            do {
                return try await work(control)
            } catch .notSupported {
                privacyChoice = await passOver(privacyChoice) { await $0.privacy(access) }
            }
        }
    }

    /// Everything it can be controlled with, worked out (for the settings).
    public func controls() async -> Config.Controls {
        Config.Controls(ptz: await ptz()?.abilities, talk: await talk()?.abilities, items: await items().map(\.item))
    }

    /// Does `work` with the PTZ control; if that provider says it can't, with the next one that can.
    public func withPTZ<T: Sendable>(_ work: (any PTZControl) async throws(ControlFailure) -> T) async throws(ControlFailure) -> T {
        while true {
            guard let control = await ptz() else { throw .notSupported }
            do {
                return try await work(control)
            } catch .notSupported {
                ptzChoice = await passOver(ptzChoice) { await $0.ptz(access) }
            }
        }
    }

    public func withTalk<T: Sendable>(_ work: (any TalkControl) async throws(ControlFailure) -> T) async throws(ControlFailure) -> T {
        while true {
            guard let control = await talk() else { throw .notSupported }
            do {
                return try await work(control)
            } catch .notSupported {
                talkChoice = await passOver(talkChoice) { await $0.talk(access) }
            }
        }
    }

    /// The camera's items, in their groups' order: each from the first provider (in order of preference) that
    /// declares it, so one camera can mix its make's own with ONVIF's.
    public func items() async -> [any ItemControl] {
        if itemChoice == nil || (itemsRetry.map { $0 < Date() } ?? false) { await resolveItems(from: 0, keeping: [:]) }
        return (itemChoice ?? [:]).values.map(\.control).sorted {
            (Config.Controls.Item.Group.allCases.firstIndex(of: $0.item.group) ?? 0, $0.item.order, $0.item.id)
                < (Config.Controls.Item.Group.allCases.firstIndex(of: $1.item.group) ?? 0, $1.item.order, $1.item.id)
        }
    }

    /// Does `work` with the item; if its provider says it can't, with the next one that declares it.
    public func withItem<T: Sendable>(_ id: String, _ work: (any ItemControl) async throws(ControlFailure) -> T) async throws(ControlFailure) -> T {
        _ = await items()
        while true {
            guard let chosen = itemChoice?[id] else { throw .notSupported }
            do {
                return try await work(chosen.control)
            } catch .notSupported {
                itemChoice?[id] = nil
                for index in providers.indices where index > chosen.index {
                    if case let .yes(list) = await providers[index].items(access), let next = list.first(where: { $0.item.id == id }) {
                        itemChoice?[id] = (next, index)
                        break
                    }
                }
            }
        }
    }

    /// A provider couldn't be asked about its items, so they'll be asked again (for tests).
    var retryPending: Bool { itemsRetry != nil }

    private func resolveItems(from start: Int, keeping: [String: (control: any ItemControl, index: Int)]) async {
        var chosen = keeping
        var retry: Date?
        for index in providers.indices where index >= start {
            switch await providers[index].items(access) {
            case let .yes(list):
                for control in list where chosen[control.item.id] == nil { chosen[control.item.id] = (control, index) }
            case .no:
                continue
            case .unknown:
                retry = retry ?? Date().addingTimeInterval(Self.retry)
            }
        }
        itemChoice = chosen
        itemsRetry = retry
    }

    /// The first provider from `start` that offers the feature; if one before it couldn't be asked, only
    /// for a while.
    private func first<T>(from start: Int, _ ask: (CameraProvider) async -> Offer<T>) async -> Choice<T> {
        var until: Date?
        for index in providers.indices where index >= start {
            switch await ask(providers[index]) {
            case let .yes(control): return .chosen(control, index: index, until: until)
            case .no: continue
            case .unknown: until = until ?? Date().addingTimeInterval(Self.retry)
            }
        }
        return .none(until: until)
    }

    private func resolve<T>(_ choice: Choice<T>, _ ask: (CameraProvider) async -> Offer<T>) async -> Choice<T> {
        switch choice {
        case .unknown: return await first(from: 0, ask)
        case let .chosen(_, _, until?) where until < Date(): return await first(from: 0, ask)
        case let .none(until?) where until < Date(): return await first(from: 0, ask)
        default: return choice
        }
    }

    /// The chosen one passed over (it said it can't, when used): the next after it.
    private func passOver<T>(_ choice: Choice<T>, _ ask: (CameraProvider) async -> Offer<T>) async -> Choice<T> {
        guard case let .chosen(_, index, _) = choice else { return .none(until: nil) }
        return await first(from: index + 1, ask)
    }
}
