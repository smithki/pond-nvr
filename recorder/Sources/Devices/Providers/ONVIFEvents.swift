// A camera's own events over ONVIF: a pull-point subscription (CreatePullPointSubscription, then PullMessages
// again and again, each held open by the camera until something happens or a few seconds pass, renewed
// before it runs out), read for motion (plain motion, and the person, vehicle and animal detection many
// cameras do) and a doorbell's button. Drives HomeKit's motion sensor, so HomeKit Secure Video records
// cameras of any make that does ONVIF events.
import Foundation

/// One event as the camera sent it: its topic, what changed, and its values.
public struct ONVIFEvent: Equatable, Sendable {
    /// E.g. "tns1:RuleEngine/CellMotionDetector/Motion".
    public var topic: String
    /// "Initialized" (the state when subscribing), "Changed" or "Deleted".
    public var operation: String
    /// The source items (which video source or rule it is about) and the data items (IsMotion, State, …).
    public var source: [String: String]
    public var data: [String: String]
    /// When the camera says it happened (its clock).
    public var time: Date?

    /// The first true or false among the data items: whether the thing is happening.
    public var isOn: Bool? {
        for (_, value) in data.sorted(by: { $0.key < $1.key }) {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: continue
            }
        }
        return nil
    }

    public enum Kind: Equatable, Sendable { case motion, doorbell, other }

    /// What the topic (or its data item's name) says the event is.
    public var kind: Kind {
        let words = ([topic] + data.keys).joined(separator: " ").lowercased()
        if ["visitor", "doorbell", "ring"].contains(where: words.contains) { return .doorbell }
        if ["motion", "people", "person", "human", "vehicle", "car", "dogcat", "animal", "pet", "objectdetect"]
            .contains(where: words.contains) { return .motion }
        return .other
    }

    /// Which thing it is about, so the same detector's on and off match up.
    var key: String { topic + "|" + source.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",") }

    /// The events in a PullMessages reply.
    static func all(in document: XMLNode) -> [ONVIFEvent] {
        document.all("NotificationMessage").map { message in
            let inner = message.first("Message")?.first("Message") ?? message.first("Message")
            func items(_ section: String) -> [String: String] {
                var out: [String: String] = [:]
                for item in inner?.first(section)?.all("SimpleItem") ?? [] {
                    if let name = item.attribute("Name") { out[name] = item.attribute("Value") ?? "" }
                }
                return out
            }
            let time = inner?.attribute("UtcTime").flatMap { text in
                ISO8601DateFormatter().date(from: text) ?? {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.date(from: text)
                }()
            }
            return ONVIFEvent(topic: message.first("Topic")?.trimmed ?? "", operation: inner?.attribute("PropertyOperation") ?? "",
                              source: items("Source"), data: items("Data"), time: time)
        }
    }
}

/// From events to what HomeKit wants: whether anything is moving (any motion detector on), and the button.
public struct ONVIFEventTracker: Sendable {
    /// Each motion detector's state, and the button's (kept apart: a doorbell may never say a press ended).
    private var detecting: [String: Bool] = [:]
    private var lastPress: Date?
    public private(set) var moving = false

    public init() {}

    public struct Change: Equatable, Sendable {
        /// The new motion state, if it changed.
        public var motion: Bool?
        public var pressed = false
    }

    public mutating func take(_ event: ONVIFEvent, at now: Date = Date()) -> Change {
        var change = Change()
        guard let value = event.isOn else { return change }
        switch event.kind {
        case .motion:
            detecting[event.key] = value
            let now = detecting.values.contains(true)
            if now != moving {
                moving = now
                change.motion = now
            }
        case .doorbell:
            // A press: each time it says on (some doorbells never say off again), but not the state found on
            // subscribing, nor the same press told twice.
            guard value, event.operation != "Initialized" else { break }
            if lastPress.map({ now.timeIntervalSince($0) > 3 }) ?? true {
                change.pressed = true
                lastPress = now
            }
        case .other:
            break
        }
        return change
    }
}

extension ONVIFClient {
    /// A pull-point subscription: where to pull its messages from.
    public func subscribe(events: URL, seconds: Int = 60) async throws(Failure) -> URL {
        let reply = try await call(events, """
        <CreatePullPointSubscription xmlns="http://www.onvif.org/ver10/events/wsdl">\
        <InitialTerminationTime>PT\(seconds)S</InitialTerminationTime></CreatePullPointSubscription>
        """)
        guard let address = reply.first("SubscriptionReference")?.first("Address")?.trimmed, let url = reachable(address) else {
            throw Failure(description: "no subscription address in the answer")
        }
        return url
    }

    /// The events since the last pull, waiting up to `seconds` for one.
    public func pull(_ subscription: URL, seconds: Int = 10) async throws(Failure) -> [ONVIFEvent] {
        let reply = try await call(subscription, """
        <PullMessages xmlns="http://www.onvif.org/ver10/events/wsdl"><Timeout>PT\(seconds)S</Timeout>\
        <MessageLimit>32</MessageLimit></PullMessages>
        """, action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
             timeout: TimeInterval(seconds + 10))
        return ONVIFEvent.all(in: reply)
    }

    public func renew(_ subscription: URL, seconds: Int = 60) async throws(Failure) {
        _ = try await call(subscription, "<Renew xmlns=\"http://docs.oasis-open.org/wsn/b-2\"><TerminationTime>PT\(seconds)S</TerminationTime></Renew>",
                           action: "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest")
    }

    public func unsubscribe(_ subscription: URL) async {
        _ = try? await call(subscription, "<Unsubscribe xmlns=\"http://docs.oasis-open.org/wsn/b-2\"/>",
                            action: "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest")
    }
}

/// An ONVIF camera's motion and button, watched until stopped: subscribes, pulls, renews; after a failure it
/// subscribes again, a little later each time.
final class ONVIFEvents: CameraEvents, @unchecked Sendable {
    let host: String
    let username: String
    let password: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(host: String, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    func start(motion: @escaping @Sendable (Bool) -> Void, pressed: @escaping @Sendable () -> Void,
               state: @escaping @Sendable (DoorbellButtonState) -> Void) {
        let (host, username, password) = (self.host, self.username, self.password)
        let t = Task.detached {
            var tracker = ONVIFEventTracker()
            var reported: DoorbellButtonState?
            func report(_ s: DoorbellButtonState) {
                if s != reported { reported = s; state(s) }
            }
            var pause = 5.0
            while !Task.isCancelled {
                guard let client = await ONVIFClient.connect(host: host, username: username, password: password) else {
                    report(.unreachable)
                    try? await Task.sleep(for: .seconds(pause))
                    pause = min(pause * 2, 60)
                    continue
                }
                do throws(ONVIFClient.Failure) {
                    guard let events = try await client.services()[ONVIF.events] else {
                        report(.notSupported)
                        return
                    }
                    let subscription = try await client.subscribe(events: events)
                    report(.watching)
                    pause = 5
                    var renewAt = Date().addingTimeInterval(40)
                    defer { Task { await client.unsubscribe(subscription) } }
                    while !Task.isCancelled {
                        for event in try await client.pull(subscription) {
                            let change = tracker.take(event)
                            if let moving = change.motion { motion(moving) }
                            if change.pressed { pressed() }
                        }
                        if Date() > renewAt {
                            try await client.renew(subscription)
                            renewAt = Date().addingTimeInterval(40)
                        }
                    }
                } catch {
                    report(error.loginRefused ? .loginRefused : .unreachable)
                    // Whatever was moving is not known to be any more.
                    if tracker.moving { motion(false) }
                    tracker = ONVIFEventTracker()
                    try? await Task.sleep(for: .seconds(error.loginRefused ? 60 : pause))
                    pause = min(pause * 2, 60)
                }
            }
        }
        lock.withLock { task = t }
    }

    func stop() { lock.withLock { task?.cancel() } }
}

extension ONVIFClient.Failure {
    /// The camera turned down the login (a SOAP fault such as ter:NotAuthorized).
    var loginRefused: Bool { description.range(of: "authori", options: .caseInsensitive) != nil }
}
