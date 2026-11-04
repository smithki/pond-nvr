// Other Ponds' events in the Events view: asked of this Mac's service (which asks each Pond), shown beside this Mac's
// as events with ids of their own (`event@pond`). Their pictures and clips are fetched by the service into a cache as
// they're wanted; a clip plays as it comes (GrowingFileLoader: the player is given its bytes from the file growing in
// order, waiting for those still on their way), so it starts without waiting for the whole of it.
import AVFoundation
import Detection
import Devices
import Foundation
import NVRCore
import SwiftUI
import UniformTypeIdentifiers

extension TimelineEvent {
    /// The other Pond it's from (nil: this Mac's).
    var pond: String? { ControlSocket.RemotePond.split(id)?.pond }

    init(remote e: ControlSocket.RemoteEvent) {
        let box = e.box.flatMap { $0.count == 4 ? Detection.Box(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        let event = ControlSocket.RemotePond.split(e.id)?.camera ?? e.id
        self.init(id: e.id, camera: e.camera, kind: .init(DetectedCategory(rawValue: e.category) ?? .other), start: e.start,
                  end: e.ongoing ? max(e.end, Date()) : max(e.end, e.start.addingTimeInterval(1)), summary: e.summary,
                  snapshot: e.picture ? URL(fileURLWithPath: ControlSocket.RemoteEvent.file(pond: e.pond, event: event, clip: false)) : nil,
                  ongoing: e.ongoing,
                  clip: e.clipBytes == nil ? nil : URL(fileURLWithPath: ControlSocket.RemoteEvent.file(pond: e.pond, event: event, clip: true)),
                  clipStart: e.clipStart, box: box, confidence: e.confidence, labels: e.labels, zones: e.zones)
    }
}

extension AppModel {
    /// Other Ponds' events begun since `from`, as shown (none while this Mac alone is).
    func remoteEvents(since from: Date) async -> [TimelineEvent] {
        guard shownPonds != .this, !otherPonds.isEmpty else { return [] }
        var request = ControlSocket.Request(camera: "", action: "remote.all-events")
        request.seconds = Date().timeIntervalSince(from)
        let found = await controlClient.ask(request, timeout: 30).remoteEvents ?? []
        return found.filter { shownPonds.includes($0.pond) }.map(TimelineEvent.init(remote:))
    }

    /// An event's picture or clip from another Pond: fetched by the service (or on its way), and how far it's got.
    nonisolated static func remoteFile(_ event: String, clip: Bool, client: ControlClient) async -> ControlSocket.RemoteFile? {
        var request = ControlSocket.Request(camera: "", action: "remote.event-file")
        request.event = event
        request.file = clip ? "clip" : "picture"
        return await client.ask(request, timeout: 10).remoteFile
    }

    /// Another Pond's event's picture, fetched if it isn't yet (up to half a minute): whether it's there now.
    nonisolated static func fetchPicture(_ event: TimelineEvent, client: ControlClient) async -> Bool {
        guard event.pond != nil, let picture = event.snapshot else { return false }
        for _ in 0 ..< 60 {
            if FileManager.default.fileExists(atPath: picture.path) { return true }
            guard let file = await remoteFile(event.id, clip: false, client: client), file.problem == nil else { return false }
            if file.done { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}

/// A file being fetched, given to a player as it grows: what's there is read as it's asked for, and what isn't yet is
/// waited for. Its size, and how much has come, from the service (asked as it goes).
final class GrowingFileLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The address the asset is made with (its own scheme, so the player asks this loader for it).
    static let scheme = "pond-growing"

    let event: String
    let client: ControlClient
    let queue = DispatchQueue(label: "pond.growing-file")
    private let lock = NSLock()
    private var latest: ControlSocket.RemoteFile?
    private var asked = Date.distantPast

    init(event: String, client: ControlClient) {
        self.event = event
        self.client = client
    }

    /// An asset for the event's clip, read through a loader (kept alive with it).
    static func asset(event: String, client: ControlClient) -> (AVURLAsset, GrowingFileLoader) {
        let loader = GrowingFileLoader(event: event, client: client)
        let asset = AVURLAsset(url: URL(string: "\(scheme)://clip/\(UUID().uuidString).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    /// How the fetch is going (asked of the service at most every 200 ms).
    func status() async -> ControlSocket.RemoteFile? {
        if let latest = lock.withLock({ Date().timeIntervalSince(asked) < 0.2 ? self.latest : nil }) { return latest }
        let now = await AppModel.remoteFile(event, clip: true, client: client)
        lock.withLock {
            if let now { latest = now }
            asked = Date()
        }
        return now
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        Task { await serve(request) }
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async {
        let deadline = Date().addingTimeInterval(60)
        while !request.isCancelled, Date() < deadline {
            guard let file = await status() else { return request.finishLoading(with: CocoaError(.fileReadUnknown)) }
            if let problem = file.problem { return request.finishLoading(with: NSError(domain: "Pond", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])) }
            // Its size, once known (a fetch just begun hasn't heard it yet; one already whole is read from its file).
            let size = file.done ? ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) : file.bytes
            guard size > 0 else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if let info = request.contentInformationRequest {
                info.contentType = UTType.mpeg4Movie.identifier
                info.contentLength = Int64(size)
                info.isByteRangeAccessSupported = true
            }
            guard let data = request.dataRequest else { return request.finishLoading() }
            let end = data.requestsAllDataToEndOfResource ? Int64(size) : min(Int64(size), data.requestedOffset + Int64(data.requestedLength))
            let available = Int64(file.done ? size : file.received)
            let at = data.currentOffset
            if at >= end { return request.finishLoading() }
            if at < available, let path = file.done ? file.path : file.partial, let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(at))
                if let chunk = try? handle.read(upToCount: Int(min(available, end) - at)), !chunk.isEmpty {
                    data.respond(with: chunk)
                    continue
                }
            }
            // (Not come yet, or the file was just moved into place: asked again in a moment.)
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !request.isCancelled { request.finishLoading(with: CocoaError(.fileReadUnknown)) }
    }
}

/// Another Pond's event's clip, looping and muted, as it comes (the Timeline's, in place of a recording: theirs stay
/// at their Pond).
struct RemoteClipPlayer: View {
    let event: TimelineEvent
    let client: ControlClient
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var loader: GrowingFileLoader?

    var body: some View {
        ZStack {
            Color.black
            if let player { PlayerLayerView(player: player) }
        }
        .task {
            guard let clip = event.clip else { return }
            let item: AVPlayerItem
            if FileManager.default.fileExists(atPath: clip.path) {
                item = AVPlayerItem(asset: AVURLAsset(url: clip))
            } else {
                let (asset, loader) = GrowingFileLoader.asset(event: event.id, client: client)
                self.loader = loader
                item = AVPlayerItem(asset: asset)
            }
            let length = (event.ongoing ? Date() : event.end).timeIntervalSince(event.clipStart ?? event.start) + 3
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: item,
                                    timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: max(1, length), preferredTimescale: 600)))
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}
