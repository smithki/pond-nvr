// The Events view's details panel: one event in full, its recording looping with what was found boxed over it,
// what was seen, where and when, and the way to the timeline or to deleting it.
import AppKit
import AVFoundation
import Detection
import Devices
import Recorder
import SwiftUI
import Watch

/// One event in full: its recording from a little before to a little after, looping, what was found boxed over it;
/// what was seen, where and when; and the way to the timeline.
struct EventDetail: View {
    let event: TimelineEvent
    let camera: String
    let recordings: String
    let source: EventSource?
    let watch: () -> Void
    let close: () -> Void
    let delete: () -> Void
    /// The event before and after it (in what's shown), if there are.
    var earlier: (() -> Void)?
    var later: (() -> Void)?
    /// The watch button's height (the menu beside it is drawn as tall), and the pointer over the menu.
    @State private var actionHeight = 0.0
    @State private var menuHovered = false

    static let width = 380.0
    /// Shown from this long before it to this long after.
    static let around = 3.0

    @AppStorage("eventBoxes") private var boxes = true
    /// Made once the clip's ready (not with each redraw), let go when the panel goes.
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    /// Another Pond's clip's loader, while it's being fetched (kept for as long as its player reads through it).
    @State private var growing: GrowingFileLoader?
    @Environment(AppModel.self) private var model
    var client: ControlClient { model.controlClient }
    /// The wall time of the clip's start, and what was found in it.
    @State private var origin: Date?
    @State private var sightings: [Sighting] = []
    @State private var noRecording = false
    /// The recording file it begins in (or its clip, `isClip`).
    @State private var recording: String?
    @State private var isClip = false

    var aspect: Double { CameraAspect.known(event.camera) ?? 16.0 / 9.0 }
    @Environment(\.panelCovers) private var covers

    /// Its corners: 18 pt, floating beside the cards; over them (a narrow window, down to its bottom edge), the bottom
    /// two follow the window's curve.
    static func shape(covering: Bool) -> ConcentricRectangle { .panel(radius: 18, byWindowBottom: covering) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                clip
                seen
                facts
                actions
            }
            .padding(16)
        }
        // (Its scroller when there's more than fits, as the system shows them: on scrolling, or always by the Mac's
        // setting.)
        .scrollIndicators(.automatic)
        .contentMargins(.vertical, 8, for: .scrollIndicators)
        .background(.quaternary.opacity(0.5), in: Self.shape(covering: covers))
        .task { await prepare() }
        .onDisappear {
            looper?.disableLooping()
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
        }
    }

    /// What it was, in a sentence; where and how long ago; the way to the events either side, and out.
    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                KindBadge(event: event)
                Spacer()
                HStack(spacing: 2) {
                    // As the grid has them: newer to the left, older to the right.
                    round("chevron.left", help: "Newer event (\u{2190})", action: later)
                    round("chevron.right", help: "Older event (\u{2192})", action: earlier)
                }
                round("xmark", help: "Close (Esc)", action: close)
            }
            Text(event.summary)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(camera) \u{00B7} \(event.ongoing ? "now" : event.start.formatted(.relative(presentation: .named)))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    func round(_ symbol: String, help: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol).font(.callout.weight(.semibold)).frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(action == nil)
        .opacity(action == nil ? 0.4 : 1)
        .help(help)
    }

    /// What was seen: a chip each, the most at once of each.
    @ViewBuilder
    var seen: some View {
        if !event.labels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Seen").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(event.labels.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }, id: \.key) { label, n in
                        let kind = TimelineEvent.Kind(DetectedCategory.forLabel(label))
                        HStack(spacing: 5) {
                            Image(systemName: kind.symbol).foregroundStyle(kind.color)
                            Text(n == 1 ? label : "\(n) \(CameraEvent.plural(label))")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(kind.color.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
    }

    /// When, how long, how sure, where: a tile each, two a row.
    var facts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            tile("Started", event.start.formatted(date: .omitted, time: .standard),
                 detail: event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            tile("Ended", event.ongoing ? "Going on" : event.end.formatted(date: .omitted, time: .standard))
            tile("Length", event.ongoing ? "So far \(EventCallout.length(event.seconds))" : EventCallout.length(event.seconds))
            if let confidence = event.confidence {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confidence").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int((confidence * 100).rounded()))%").font(.title3.weight(.semibold).monospacedDigit())
                    ProgressView(value: confidence).tint(event.kind.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help("How sure the model was, at its surest sighting")
            }
            tile("Zones", event.zones.isEmpty ? "Anywhere" : event.zones.joined(separator: ", "))
            tile("Camera", camera)
        }
    }

    func tile(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .textSelection(.enabled)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var actions: some View {
        HStack(spacing: 8) {
            // (Another Pond's event: its clip is all there is of it here; its recordings stay at its Pond.)
            if event.pond == nil {
                Button(action: watch) {
                    Label("Watch on Timeline", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { actionHeight = $0 }
            } else {
                Spacer()
            }
            Menu {
                if let snapshot = event.snapshot {
                    Button("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
                }
                if let recording {
                    Button(isClip ? "Show Clip in Finder" : "Show Recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording)])
                    }
                }
                if event.pond == nil {
                    Divider()
                    // What it was (for what's like it, from now on).
                    if event.quieted != nil {
                        Button("It Was Something", systemImage: "exclamationmark.bubble") { model.say(.something, of: event) }
                    } else {
                        Button("This Wasn\u{2019}t Anything", systemImage: "moon.zzz") { model.say(.nothing, of: event) }
                    }
                    Divider()
                    Button("Delete Event…", role: .destructive, action: delete)
                }
            } label: {
                // Drawn here, not by the menu's own button (smaller than a large one, whatever its size's set to):
                // a capsule as tall as the button beside it.
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: max(actionHeight, 28))
                    .background(.fill.opacity(menuHovered ? 1 : 0.7), in: Capsule())
                    .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { menuHovered = $0 }
            .help("More")
        }
    }

    /// The recording round it, looping, with its boxes; its picture until the recording's ready (or if there's none).
    var clip: some View {
        ZStack {
            EventPicture(event: event, aspect: aspect).opacity(origin == nil ? 1 : 0)
            if origin != nil, let player {
                PlayerLayerView(player: player)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                if boxes, let origin {
                    SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        let seconds = player.currentTime().seconds
                        DetectionBoxes(boxes: seconds.isFinite ? TimelineModel.glide(in: sightings, at: origin.addingTimeInterval(seconds)) : [],
                                       aspect: aspect)
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if origin != nil {
                Button { boxes.toggle() } label: {
                    Image(systemName: "viewfinder").symbolVariant(boxes ? .fill : .none)
                        .font(.callout).frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(8)
                .help(boxes ? "Stop drawing boxes around identified objects" : "Draw boxes around identified objects")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if noRecording {
                Text(event.pond == nil ? "No recording of this" : "No clip of this yet").font(.caption).padding(6).glassEffect(.regular, in: .capsule).padding(8)
            }
        }
    }

    /// Its clip (its own, once the service has made it; until then, the recording from a little before to a little
    /// after), looping and muted, and what was found in it.
    func prepare() async {
        // Not while the panel's sliding in (or the arrows are stepping through): the player's made once it's still.
        try? await Task.sleep(for: .seconds(0.45))
        guard !Task.isCancelled else { return }
        let camera = event.camera, source = self.source
        // Another Pond's: its clip, played as it comes (fetched by the service); only its picture until it has one.
        if event.pond != nil {
            guard let clip = event.clip, let start = event.clipStart else {
                noRecording = true
                return
            }
            // Its length as the event has it (the clip's own isn't known until all of it's come): the event, and the
            // few seconds the service keeps either side.
            let length = (event.ongoing ? Date() : event.end).timeIntervalSince(start) + Self.around
            let item: AVPlayerItem
            if FileManager.default.fileExists(atPath: clip.path) {
                item = AVPlayerItem(asset: AVURLAsset(url: clip))
                recording = clip.path
                isClip = true
            } else {
                let (asset, loader) = GrowingFileLoader.asset(event: event.id, client: client)
                growing = loader
                item = AVPlayerItem(asset: asset)
            }
            guard !Task.isCancelled else { return }
            play(item, length: max(1, length), from: start, sightings: [])
            return
        }
        // Its own clip, when the service has made it (kept as long as events are): played as it is.
        if let clip = event.clip, let start = event.clipStart, FileManager.default.fileExists(atPath: clip.path) {
            let asset = AVURLAsset(url: clip)
            if let duration = try? await asset.load(.duration), duration.seconds > 0.5 {
                let end = start.addingTimeInterval(duration.seconds)
                let found = await Task.detached { source?.sightings(camera: camera, from: start, to: end) ?? [] }.value
                guard !Task.isCancelled else { return }
                recording = clip.path
                isClip = true
                play(AVPlayerItem(asset: asset), length: duration.seconds, from: start, sightings: found)
                return
            }
        }
        // Until then (or if it's gone): the recording round it.
        let from = event.start.addingTimeInterval(-Self.around)
        let to = (event.ongoing ? Date() : event.end).addingTimeInterval(Self.around)
        let recordings = self.recordings
        let spans = await Task.detached {
            RecordingIndex.spans(base: recordings, camera: camera, from: from, to: to, writing: true)
        }.value
        recording = spans.first { $0.start <= event.start && event.start < $0.end }?.path ?? spans.first?.path
        guard let built = await TimelineModel.composition(spans, from: from) else {
            noRecording = true
            return
        }
        let found = await Task.detached { source?.sightings(camera: camera, from: from, to: to) ?? [] }.value
        let length = min(built.end, to).timeIntervalSince(from)
        guard length > 0.5 else {
            noRecording = true
            return
        }
        guard !Task.isCancelled else { return }
        play(AVPlayerItem(asset: built.composition), length: length, from: from, sightings: found)
    }

    /// Played, looping and muted, from `from` (its first moment's time: the boxes follow it).
    func play(_ item: AVPlayerItem, length: Double, from: Date, sightings found: [Sighting]) {
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item,
                                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600)))
        self.player = player
        sightings = found
        origin = from
        player.play()
    }
}
