// Timeline: the recorded video on top, playback controls in a glass bar, and below a lane per camera with
// what was recorded that day. Click or drag on the lanes to move through the day; click a lane to switch
// camera.
import AVFoundation
import NVRCore
import SwiftUI

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    var timeline: TimelineModel { model.timeline }
    /// The event under the pointer right now.
    @State private var hovered: EventHover?
    /// The event the callout shows: follows `hovered`, but lingers briefly after the pointer leaves a mark,
    /// so moving between events slides one callout along instead of closing and reopening it.
    @State private var shown: EventHover?
    @State private var dismissal: Task<Void, Never>?
    @State private var calloutSize = CGSize.zero

    /// The lanes panel's share of the view's height, chosen by dragging the grip; below zero, automatic.
    @AppStorage("timelineLanesShare") private var lanesShare = -1.0
    @State private var dragStartHeight: Double?
    /// Once the view has opened where the timeline is: until then nothing glides (the view would otherwise
    /// slide from wherever it was when last shown).
    @State private var settled = false

    /// Without a choice, the lanes take what they need, up to this share of the height.
    static let automaticShare = 0.4
    static let linger = Duration.milliseconds(350)
    static let slide = Animation.snappy(duration: 0.22)

    /// The coordinate space the lanes report their marks in, and the callout is placed in.
    static let space = "timeline"

    var body: some View {
        let cameras = model.config?.cameras ?? []
        GeometryReader { geo in
            content(cameras: cameras, height: geo.size.height)
        }
    }

    /// The lanes panel's height: what the user chose, or what the lanes need up to the automatic share;
    /// never less than two lanes, nor more than all of them.
    func lanesHeight(cameras n: Int, total: Double) -> Double {
        let full = TimelineLanes.fullHeight(cameras: n)
        let chosen = lanesShare >= 0 ? lanesShare * total : min(full, Self.automaticShare * total)
        return min(full, max(TimelineLanes.minimumHeight(cameras: n), chosen))
    }

    func content(cameras: [Config.Camera], height total: Double) -> some View {
        let lanes = lanesHeight(cameras: cameras.count, total: total)
        return VStack(spacing: 8) {
            ZStack {
                Color.black
                PlayerLayerView(player: timeline.player)
                if timeline.isLive, let id = timeline.camera, let camera = cameras.first(where: { $0.id == id }) {
                    TimelineLive(camera: camera).id(camera.id)
                }
                if timeline.atEnd, !timeline.isLive {
                    EndOfRecording(timeline: timeline)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                overlayMessage
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let id = timeline.camera, let camera = cameras.first(where: { $0.id == id }) {
                    Text(camera.name)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .padding(12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if timeline.isLive {
                    LiveBadge().padding(12).transition(.opacity)
                } else if let event = timeline.currentEvent {
                    EventBadge(event: event).padding(12).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: timeline.isLive)
            .animation(.snappy(duration: 0.25), value: timeline.atEnd)
            .animation(.easeInOut(duration: 0.2), value: timeline.currentEvent?.id)
            .onTapGesture { timeline.togglePlay() }
            .frame(minHeight: 140)

            SplitGrip { dy in
                let start = dragStartHeight ?? lanes
                dragStartHeight = start
                lanesShare = max(0.1, min(0.8, (start - dy) / total))
            } onEnd: {
                dragStartHeight = nil
            } onReset: {
                lanesShare = -1
            }

            TimelineControls(timeline: timeline)

            VStack(alignment: .leading, spacing: 8) {
                if !timeline.dayEvents.isEmpty {
                    EventFilters(timeline: timeline)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                let visible = timeline.visible
                TimelineLanes(timeline: timeline, cameras: cameras,
                              start: visible.lowerBound.timeIntervalSinceReferenceDate,
                              length: visible.upperBound.timeIntervalSince(visible.lowerBound),
                              playhead: timeline.playhead?.timeIntervalSinceReferenceDate ?? .nan,
                              hovered: $hovered, highlighted: shown?.event.id,
                              reorder: { model.moveCamera($0, onto: $1) })
                    // A jump out of view (another day, live from long ago) cross-fades: the lanes are drawn
                    // afresh at the new place as the old ones fade.
                    .id(timeline.jumps)
                    .transition(.opacity)
                    // Following the playhead (a click, a drag, playing, a zoom), the view glides there; panned by
                    // hand (the ruler, two fingers), it follows the hand at once. Not while the view opens: it
                    // shows where it is at once instead of gliding from wherever it was last.
                    .animation(settled && timeline.panStart == nil ? .snappy(duration: 0.35) : nil, value: visible)
                    .animation(settled ? .snappy(duration: 0.35) : nil, value: timeline.playhead)
                    .animation(settled ? .easeInOut(duration: 0.25) : nil, value: timeline.jumps)
                    .frame(height: lanes)
            }
            // The filters' row coming or going: the lanes move up or down with it, rather than jump.
            .animation(settled ? EventFilters.animation : nil, value: timeline.dayEvents.isEmpty)
        }
        .padding(16)
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { callout }
        .onChange(of: hovered) { _, now in
            dismissal?.cancel()
            if let now {
                withAnimation(shown == nil ? .easeOut(duration: 0.12) : Self.slide) { shown = now }
            } else {
                dismissal = Task {
                    try? await Task.sleep(for: Self.linger)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) { shown = nil }
                }
            }
        }
        .task(id: cameras.map(\.id)) {
            timeline.source = EventSource(config: model.config)
            await timeline.load(base: model.config?.storage.recordingsPath ?? "", cameras: cameras.map(\.id))
            if let jump = model.timelineJump {
                await go(to: jump)
            } else if timeline.playhead == nil {
                await timeline.showLatest()
            }
            settled = true
            // --live: start live (for trying it, and pictures of it).
            if CommandLine.arguments.contains("--live"), !timeline.isLive {
                if timeline.camera == nil { timeline.camera = cameras.first?.id }
                timeline.goLive()
            }
            // Today, new minutes keep arriving (and the one being written grows): every 10 s, or every 5 s while
            // paused at the end (to say when more is ready to watch).
            var since = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard timeline.isToday, timeline.atEnd || Date().timeIntervalSince(since) >= 10 else { continue }
                since = Date()
                timeline.source = EventSource(config: model.config)
                await timeline.load(base: model.config?.storage.recordingsPath ?? "", cameras: cameras.map(\.id))
            }
        }
        .onDisappear { timeline.pause() }
    }

    /// The hovered event's details, centred above its mark with an arrow down to it; near the window's edges
    /// the card slides inward and the arrow stays on the mark.
    @ViewBuilder
    var callout: some View {
        GeometryReader { geo in
            if let shown {
                let cameraName = (model.config?.cameras ?? []).first { $0.id == shown.event.camera }?.name ?? ""
                let margin = 12.0
                let left = min(max(margin, shown.anchor.x - calloutSize.width / 2),
                               geo.size.width - calloutSize.width - margin)
                EventCallout(event: shown.event, camera: cameraName, arrowX: shown.anchor.x - left)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        // A new event's text changes the card's size; it resizes with the slide.
                        if calloutSize == .zero { calloutSize = size } else { withAnimation(Self.slide) { calloutSize = size } }
                    }
                    .offset(x: left, y: shown.anchor.y - calloutSize.height - 4)
                    .opacity(calloutSize == .zero ? 0 : 1)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// Shows the event at the jump's time (or just that moment), playing.
    func go(to jump: TimelineJump) async {
        model.timelineJump = nil
        await timeline.show(day: jump.time)
        if let event = timeline.events.first(where: { $0.camera == jump.camera && $0.start == jump.time }) {
            await timeline.play(event)
        } else {
            await timeline.select(camera: jump.camera)
            await timeline.seek(to: jump.time.addingTimeInterval(-TimelineModel.preRoll))
            timeline.play()
        }
    }

    @ViewBuilder
    var overlayMessage: some View {
        if timeline.loading {
            ProgressView().controlSize(.large)
        } else if timeline.nothingRecorded {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                Text(timeline.spans.values.allSatisfy(\.isEmpty) ? "Nothing recorded this day" : "Nothing recorded here")
                    .font(.headline)
                Text(model.isRecording ? "Pick a time on the timeline below." : "Start recording in Settings → Recorder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .environment(\.colorScheme, .dark)
        }
    }
}

struct TimelineControls: View {
    @Bindable var timeline: TimelineModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    Button { Task { await timeline.show(day: timeline.day.addingTimeInterval(-86400)) } } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous day")
                    DayButton(timeline: timeline)
                    Button { Task { await timeline.show(day: timeline.day.addingTimeInterval(86400)) } } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(timeline.isToday)
                    .help("Next day")
                }
                .buttonStyle(HoverButtonStyle())
                .focusEffectDisabled()
                .padding(.horizontal, 6)
                .frame(height: Self.barHeight)
                .glassEffect(.regular, in: .capsule)

                Spacer()

                HStack(spacing: 4) {
                    if !timeline.events.isEmpty {
                        Button { Task { await timeline.jumpToEvent(forward: false) } } label: {
                            Image(systemName: "backward.end.fill")
                        }
                        .keyboardShortcut("[", modifiers: [])
                        .help("Previous event ([)")
                    }
                    Button { Task { await timeline.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Back 10 seconds (←)")
                    // Live counts as playing: pausing it stops at the latest recorded moment.
                    Button { timeline.togglePlay() } label: {
                        Image(systemName: timeline.playing || timeline.isLive ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 28)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help(timeline.isLive ? "Pause: stops at the latest recorded moment (space)" : "Play or pause (space)")
                    Button { Task { await timeline.skip(10) } } label: { Image(systemName: "goforward.10") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .help("Forward 10 seconds (→)")
                    if !timeline.events.isEmpty {
                        Button { Task { await timeline.jumpToEvent(forward: true) } } label: {
                            Image(systemName: "forward.end.fill")
                        }
                        .keyboardShortcut("]", modifiers: [])
                        .help("Next event (])")
                    }
                    // Live: a solid red capsule with a pulsing dot, as broadcasts mark it. Otherwise drawn like the
                    // other buttons (grey would look disabled), its dot red and still: what it goes to.
                    Button { timeline.goLive() } label: {
                        HStack(spacing: 5) {
                            LiveDot(active: timeline.isLive, color: timeline.isLive ? .white : .red)
                            Text("LIVE").font(.callout.weight(.bold))
                        }
                        .foregroundStyle(timeline.isLive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 1)
                        .background(Capsule().fill(timeline.isLive ? Color.red : Color.clear).padding(.horizontal, -8).padding(.vertical, -4))
                        .animation(.snappy(duration: 0.2), value: timeline.isLive)
                    }
                    .keyboardShortcut("l", modifiers: [])
                    .disabled(timeline.camera == nil)
                    .help(timeline.isLive ? "Watching live" : "Jump to live (L)")
                    Menu {
                        Picker("Speed", selection: $timeline.rate) {
                            ForEach([Float(0.5), 1, 2, 4, 8, 16], id: \.self) { r in
                                Text(Self.speed(r)).tag(r)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(Self.speed(timeline.rate)).monospacedDigit().frame(minWidth: 28)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(timeline.nearPresent)
                    .opacity(timeline.nearPresent ? 0.4 : 1)
                    .help(timeline.nearPresent ? "Live and the last few minutes play in real time" : "Playback speed")
                    // Sound: for recordings and live alike, off until turned on.
                    Button { timeline.muted.toggle() } label: {
                        Image(systemName: timeline.muted || !timeline.hasAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 28)
                    }
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(!timeline.hasAudio)
                    .help(!timeline.hasAudio ? (timeline.isLive ? "This camera sends no sound" : "No sound in this recording")
                          : timeline.muted ? "Turn sound on (M)" : "Mute (M)")
                }
                .buttonStyle(HoverButtonStyle())
                .font(.title3)
                .padding(.horizontal, 8)
                .frame(height: Self.barHeight)
                .glassEffect(.regular.interactive(), in: .capsule)

                Spacer()

                HStack(spacing: 12) {
                    // Laid out at the width of the widest time, so the controls beside it stay still while
                    // scrubbing.
                    ZStack {
                        ForEach(Self.widestTimes, id: \.self) { Text($0) }
                    }
                    .hidden()
                    .overlay(alignment: .trailing) {
                        // Live: the present, in red (the LIVE button and badge say the rest).
                        // While scrubbing, the time under the pointer; otherwise the playhead's.
                        Text((timeline.scrubbing ?? timeline.playhead).map { $0.formatted(date: .omitted, time: .standard) } ?? "--:--:--")
                        .foregroundStyle(timeline.isLive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .fixedSize()
                    }
                        .font(.title3.monospacedDigit().weight(.semibold))
                    CapsuleSegments(selection: $timeline.zoom, options: TimelineModel.Zoom.allCases) { $0.title }
                        .help("How much of the day the timeline shows")
                }
                .padding(.horizontal, 12)
                .frame(height: Self.barHeight)
                .glassEffect(.regular, in: .capsule)
            }
        }
    }

    /// The height of each group of controls, so they line up as one bar.
    static let barHeight = 44.0

    /// Two-digit hours, in the morning and the evening: the label is as wide as the wider of the two.
    static let widestTimes = [10, 22].map { hour in
        (Calendar.current.date(bySettingHour: hour, minute: 58, second: 58, of: Date()) ?? Date())
            .formatted(date: .omitted, time: .standard)
    }

    static func speed(_ r: Float) -> String {
        r == 0.5 ? "½×" : "\(Int(r))×"
    }
}

/// The day shown, as a word where one fits; click for a calendar.
struct DayButton: View {
    let timeline: TimelineModel
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            Text(title).frame(minWidth: 96)
        }
        .help("Choose a day")
        .popover(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 8) {
                CalendarPicker(date: timeline.day, latest: Date()) { d in
                    choosing = false
                    Task { await timeline.show(day: d) }
                }
                HStack {
                    Spacer()
                    Button("Today") {
                        choosing = false
                        Task { await timeline.show(day: Date()) }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .disabled(timeline.isToday)
                }
            }
            .padding(14)
        }
    }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timeline.day) { return "Today" }
        if calendar.isDateInYesterday(timeline.day) { return "Yesterday" }
        return timeline.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// The ruler and one lane per camera, drawn with Canvas. Recorded stretches are a quiet fill, events bright
/// marks over them in their kind's colour; the playhead is red. Hover over an event for what happened, click
/// it to play it. The ruler stays put while the lanes scroll, and lanes get thinner as cameras are added.
struct TimelineLanes: View, @MainActor Animatable {
    let timeline: TimelineModel
    let cameras: [Config.Camera]
    /// The part of the timeline shown (seconds since the reference date, and its length), animated: a click
    /// or a drag moves the view smoothly to the new playhead instead of jumping.
    var start: Double
    var length: Double
    /// The playhead (seconds since the reference date; nil as NaN), animated with the view, so the marker
    /// glides with it instead of jumping ahead and riding back to the middle.
    var playhead: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(start, length), playhead.isNaN ? 0 : playhead) }
        set {
            start = newValue.first.first
            length = newValue.first.second
            if !playhead.isNaN { playhead = newValue.second }
        }
    }
    /// The event under the pointer, shared with TimelineView, which draws its callout.
    @Binding var hovered: EventHover?
    /// The event whose callout is showing, outlined.
    let highlighted: String?
    @State private var dragging: Date?
    /// Advanced every second while the timeline shows today, so what is being recorded (drawn up to the
    /// present) keeps growing when nothing else changes.
    @State private var clock = Date()
    /// Each camera's recording as drawn while it grows to newly loaded minutes (see CatchUp).
    @State private var catchUps: [String: CatchUp] = [:]
    /// Where the visible part started when a pan of the time axis began.
    @State private var panAnchor: Date?
    @State private var overTimeline = false
    /// The lanes' drawing width. A visible scroll bar makes it narrower than the ruler's room, and both must
    /// share one time scale.
    @State private var lanesWidth: CGFloat?
    /// The label a dragged camera is over.
    @State private var dropTarget: String?
    /// Moves the first camera to where the second is.
    let reorder: (String, String) -> Void

    static let labelWidth = 132.0
    static let rulerHeight = 26.0
    static let padding = 8.0

    /// Roomier with few cameras, never so thin that marks are hard to read or hit: with many, the lanes
    /// scroll instead.
    static func laneHeight(cameras n: Int) -> Double { n <= 6 ? 36 : 30 }

    /// The panel's height with every lane showing.
    static func fullHeight(cameras n: Int) -> Double {
        rulerHeight + laneHeight(cameras: n) * Double(max(n, 1)) + 2 * padding
    }

    /// The least height worth showing: the ruler and two lanes.
    static func minimumHeight(cameras n: Int) -> Double {
        rulerHeight + laneHeight(cameras: n) * Double(min(max(n, 1), 2)) + 2 * padding
    }

    var laneHeight: Double { Self.laneHeight(cameras: cameras.count) }

    var body: some View {
        let visible = Date(timeIntervalSinceReferenceDate: start) ... Date(timeIntervalSinceReferenceDate: start + length)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth)
                GeometryReader { geo in
                    // Dragged, the time axis pans the timeline; the lanes below move the playhead.
                    Canvas { context, size in drawRuler(context, size: size, visible: visible) }
                        .contentShape(Rectangle())

                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let perPoint = visible.upperBound.timeIntervalSince(visible.lowerBound) / max(geo.size.width, 1)
                                let start = panAnchor ?? visible.lowerBound
                                panAnchor = start
                                timeline.panStart = start
                                timeline.pan(by: -value.translation.width * perPoint)
                            }
                            .onEnded { _ in panAnchor = nil })
                        .onHover { inside in
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                        .help("Drag to move along the day")
                }
                .frame(width: lanesWidth)
                Spacer(minLength: 0)
            }
            .frame(height: Self.rulerHeight)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(cameras) { camera in label(camera).id(camera.id) }
                        }
                        .frame(width: Self.labelWidth)

                        GeometryReader { geo in
                            // Zoomed in (1 h, 15 m), what is being recorded grows with the clock frame by frame
                            // rather than a step a second; and newly loaded minutes fill in smoothly at any zoom.
                            SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { frame in
                                Canvas { context, size in
                                    drawLanes(context, size: size, visible: visible,
                                              now: smoothNow ? frame.date : clock, frame: frame.date)
                                }
                            }
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case let .active(point):
                                        let origin = geo.frame(in: .named(TimelineView.space)).origin
                                        if let event = event(at: point, width: geo.size.width, visible: visible) {
                                            let mark = markRect(event, width: geo.size.width, visible: visible)
                                            hovered = EventHover(event: event,
                                                                 anchor: CGPoint(x: origin.x + mark.midX, y: origin.y + mark.minY))
                                        } else if let stretch = privateStretch(at: point, width: geo.size.width, visible: visible) {
                                            // Too narrow for its word: what it is, on hover.
                                            let lane = laneRect(cameras.firstIndex { $0.id == stretch.camera } ?? 0, width: geo.size.width)
                                            let mid = x(stretch.start.addingTimeInterval(stretch.seconds / 2), width: geo.size.width, visible: visible)
                                            hovered = EventHover(event: stretch, anchor: CGPoint(x: origin.x + min(max(mid, 0), geo.size.width),
                                                                                                y: origin.y + lane.minY + 3))
                                        } else {
                                            hovered = nil
                                        }
                                    case .ended:
                                        hovered = nil
                                    }
                                }
                                .gesture(scrub(width: geo.size.width, visible: visible, inLanes: true))
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lanesWidth = $0 }
                    }
                    .frame(height: laneHeight * Double(cameras.count))
                }
                .scrollIndicators(.automatic)
                .onChange(of: timeline.camera) { _, id in
                    // The camera being watched stays in view, whatever changed it.
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id) } }
                }
            }
        }
        // Two-finger sideways scrolling over the timeline pans it; up and down still scroll the lanes.
        .onHover { overTimeline = $0 }
        .background(HorizontalScroll(active: overTimeline) { dx in
            let perPoint = timeline.zoom.rawValue / max(lanesWidth ?? 600, 1)
            timeline.pan(by: -dx * perPoint)
        })
        .padding(.horizontal, 14)
        .padding(.vertical, Self.padding)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: timeline.isToday) {
            while timeline.isToday, !Task.isCancelled {
                clock = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: timeline.coverage) { old, new in catchUp(from: old, to: new) }
    }

    /// Zoomed in far enough on today that a second's growth shows: drawn every frame.
    var smoothNow: Bool { timeline.isToday && [.hour, .quarter].contains(timeline.zoom) }
    var animating: Bool { smoothNow || !catchUps.isEmpty }

    /// Newly loaded recording, drawn growing from where the bar ended to where it ends now. A few seconds more
    /// (the minute being written, read again as it's written): at the clock's pace, evenly, so step after step
    /// is one steady growth rather than a start and stop each time; more (a reload after a while): quickly.
    struct CatchUp {
        var from: Date
        var to: Date
        var began: Date
        static let duration = 0.8
        /// Steps up to this long grow at the clock's pace.
        static let steady = 15.0

        var isSteady: Bool { to.timeIntervalSince(from) <= Self.steady }
        var length: Double { isSteady ? max(Self.duration, to.timeIntervalSince(from)) : Self.duration }

        func end(at time: Date) -> Date {
            let t = max(0, min(1, time.timeIntervalSince(began) / length))
            let eased = isSteady ? t : t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            return from.addingTimeInterval(to.timeIntervalSince(from) * eased)
        }
    }

    /// When a camera's last recording reaches further after a load, its bar grows there instead of jumping.
    /// Not the small steps of playing into the newest minute (the bar keeps to the playhead), nor a different
    /// day's recordings.
    func catchUp(from old: [String: [ClosedRange<Date>]], to new: [String: [ClosedRange<Date>]]) {
        let time = Date()
        for (camera, ranges) in new {
            guard let last = ranges.last, let before = old[camera]?.last?.upperBound,
                  last.upperBound.timeIntervalSince(before) > 0.5, last.upperBound.timeIntervalSince(before) < 600,
                  last.lowerBound <= before.addingTimeInterval(5) else { continue }
            let from = catchUps[camera].map { $0.end(at: time) } ?? before
            catchUps[camera] = CatchUp(from: from, to: last.upperBound, began: time)
        }
        let longest = catchUps.values.map(\.length).max() ?? CatchUp.duration
        Task {
            try? await Task.sleep(for: .seconds(longest + 0.1))
            catchUps = catchUps.filter { Date().timeIntervalSince($0.value.began) < $0.value.length }
        }
    }

    /// A camera's recording as drawn: its last stretch ends where its catch-up has reached.
    func drawnCoverage(_ camera: String, at time: Date) -> [ClosedRange<Date>] {
        var ranges = timeline.coverage[camera] ?? []
        guard let catchUp = catchUps[camera], let last = ranges.last else { return ranges }
        var end = min(last.upperBound, catchUp.end(at: time))
        // Never short of what's playing (it's recorded).
        if camera == timeline.camera, let head, head > end { end = min(last.upperBound, head) }
        if end < last.upperBound { ranges[ranges.count - 1] = last.lowerBound ... max(last.lowerBound, end) }
        return ranges
    }

    /// A camera's name: click to watch it, drag it up or down to change the cameras' order.
    func label(_ camera: Config.Camera) -> some View {
        let selected = camera.id == timeline.camera
        return Button { Task { await timeline.select(camera: camera.id) } } label: {
            Text(camera.name)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: laneHeight)
        .background(alignment: .top) {
            // Where a dragged camera will land.
            if dropTarget == camera.id {
                Capsule().fill(.tint).frame(height: 3).offset(y: -1.5)
            }
        }
        .help("\(camera.name). Drag to change the order.")
        .draggable(camera.id) {
            Text(camera.name).font(.callout.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
        .dropDestination(for: String.self) { items, _ in
            // The dragged camera's id; anything else dropped here is ignored.
            guard let moved = items.first, cameras.contains(where: { $0.id == moved }) else { return false }
            withAnimation(.snappy) { reorder(moved, camera.id) }
            return true
        } isTargeted: { inside in
            if inside { dropTarget = camera.id } else if dropTarget == camera.id { dropTarget = nil }
        }
    }

    /// Click or drag to move through the day. In the lanes, a click on an event plays it, and a click
    /// elsewhere also switches to that lane's camera.
    func scrub(width: Double, visible: ClosedRange<Date>, inLanes: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A drag moves the marker with the pointer; a click lets it glide there with the view.
                guard value.translation != .zero else { return }
                hovered = nil
                dragging = time(at: value.location.x, width: width, visible: visible)
                timeline.scrubbing = dragging
            }
            .onEnded { value in
                let t = time(at: value.location.x, width: width, visible: visible)
                let click = value.translation == .zero
                timeline.scrubbing = nil
                let lane = Int(value.location.y / laneHeight)
                let clicked = click && inLanes ? event(at: value.location, width: width, visible: visible) : nil
                Task {
                    if let clicked {
                        await timeline.play(clicked)
                        return
                    }
                    if click, inLanes, cameras.indices.contains(lane) {
                        await timeline.select(camera: cameras[lane].id)
                    }
                    await timeline.seek(to: t)
                    // After a drag, the marker stays where it was let go until the animated playhead is there
                    // too, so it does not slip back and glide forward again.
                    if !click {
                        try? await Task.sleep(for: .seconds(0.4))
                        dragging = nil
                    }
                }
            }
    }

    /// The shown event nearest a point in the lanes, within a few points, so the gaps between marks don't
    /// count as leaving them.
    func event(at point: CGPoint, width: Double, visible: ClosedRange<Date>) -> TimelineEvent? {
        let lane = Int(point.y / laneHeight)
        guard point.y >= 0, cameras.indices.contains(lane) else { return nil }
        let length = visible.upperBound.timeIntervalSince(visible.lowerBound)
        let slack = 14 / width * length
        let t = time(at: point.x, width: width, visible: visible)
        func distance(_ e: TimelineEvent) -> Double {
            t < e.start ? e.start.timeIntervalSince(t) : t > e.end ? t.timeIntervalSince(e.end) : 0
        }
        return timeline.shownEvents
            .filter { $0.camera == cameras[lane].id && distance($0) <= slack }
            .min { distance($0) < distance($1) }
    }

    /// The private stretch under a point (within a few points of a narrow one), as a hover card's "event".
    func privateStretch(at point: CGPoint, width: Double, visible: ClosedRange<Date>) -> TimelineEvent? {
        let lane = Int(point.y / laneHeight)
        guard point.y >= 0, cameras.indices.contains(lane) else { return nil }
        let camera = cameras[lane].id
        let length = visible.upperBound.timeIntervalSince(visible.lowerBound)
        let slack = 4 / width * length
        let t = time(at: point.x, width: width, visible: visible)
        let spans = Self.joined(timeline.privateSpans[camera] ?? [], to: timeline.coverage[camera] ?? [])
        guard let span = spans.first(where: { t >= $0.lowerBound.addingTimeInterval(-slack) && t <= $0.upperBound.addingTimeInterval(slack) })
        else { return nil }
        return TimelineEvent(id: "private-\(camera)-\(span.lowerBound.timeIntervalSince1970)", camera: camera, kind: .privacy,
                             start: span.lowerBound, end: span.upperBound,
                             summary: "Not recorded, shown live or in the Home app.")
    }

    /// A lane's bar, and an event's mark inside it, in the lanes canvas.
    func laneRect(_ index: Int, width: Double) -> CGRect {
        CGRect(x: 0, y: Double(index) * laneHeight + 5, width: width, height: laneHeight - 10)
    }

    func markRect(_ event: TimelineEvent, width: Double, visible: ClosedRange<Date>) -> CGRect {
        let length = visible.upperBound.timeIntervalSince(visible.lowerBound)
        let lane = laneRect(cameras.firstIndex { $0.id == event.camera } ?? 0, width: width)
        let x0 = event.start.timeIntervalSince(visible.lowerBound) / length * width
        let x1 = event.end.timeIntervalSince(visible.lowerBound) / length * width
        return CGRect(x: x0, y: lane.minY + 3, width: max(3, x1 - x0), height: lane.height - 6)
    }

    func time(at x: Double, width: Double, visible: ClosedRange<Date>) -> Date {
        let length = visible.upperBound.timeIntervalSince(visible.lowerBound)
        return visible.lowerBound.addingTimeInterval(max(0, min(1, x / width)) * length)
    }

    func x(_ date: Date, width: Double, visible: ClosedRange<Date>) -> Double {
        date.timeIntervalSince(visible.lowerBound) / visible.upperBound.timeIntervalSince(visible.lowerBound) * width
    }

    /// The marker's time: the drag while dragging (it follows the pointer), else the animated playhead.
    var head: Date? { dragging ?? (playhead.isNaN ? nil : Date(timeIntervalSinceReferenceDate: playhead)) }

    /// Hour ticks (local time), and the playhead's knob.
    func drawRuler(_ context: GraphicsContext, size: CGSize, visible: ClosedRange<Date>) {
        // The spacing for the length shown now, not the zoom being moved to: while a zoom animates, the
        // ticks and labels step along with it instead of crowding a day with a quarter hour's labels.
        let shownZoom = TimelineModel.Zoom.allCases.sorted { $0.rawValue < $1.rawValue }
            .first { $0.rawValue >= length * 0.98 } ?? .day
        let ticks = shownZoom.ticks
        // Where the last label drawn ends: one that would run into it is left out.
        var lastLabelEnd = -Double.infinity
        // The marks (each midnight's day, where recording starts) have their places first; an hour label that
        // would run into one is left out (its tick stays).
        let marks = rulerMarkRects(context, size: size, visible: visible).map { $0.insetBy(dx: -4, dy: 0) }
        // Counted from the midnight before the view, which may span days.
        let base = Calendar.current.startOfDay(for: visible.lowerBound)
        var t = (visible.lowerBound.timeIntervalSince(base) / ticks.minor).rounded(.down) * ticks.minor
        while t <= visible.upperBound.timeIntervalSince(base) {
            let date = base.addingTimeInterval(t)
            let px = x(date, width: size.width, visible: visible)
            let major = t.truncatingRemainder(dividingBy: ticks.major) == 0
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: size.height - (major ? 9 : 5)))
            tick.addLine(to: CGPoint(x: px, y: size.height - 1))
            context.stroke(tick, with: .style(.secondary.opacity(major ? 0.8 : 0.4)), lineWidth: 1)
            if major {
                let hourOnly = shownZoom == .day || shownZoom == .sixHours && t.truncatingRemainder(dividingBy: 3600) == 0
                // Midnight is drawn on its own (below), as where one day becomes the next.
                if t.truncatingRemainder(dividingBy: 86400) != 0 {
                    let label = context.resolve(Text(date.formatted(hourOnly ? .dateTime.hour() : .dateTime.hour().minute()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary))
                    let box = label.measure(in: size)
                    let rect = CGRect(x: px + 3, y: 2, width: box.width, height: box.height)
                    if !marks.contains(where: { $0.intersects(rect) }), rect.minX > lastLabelEnd + 6 {
                        context.draw(label, at: rect.origin, anchor: .topLeading)
                        lastLabelEnd = rect.maxX
                    }
                }
            }
            t += ticks.minor
        }
        drawRulerMarks(context, size: size, visible: visible)
        if let head, visible.contains(head) {
            let px = x(head, width: size.width, visible: visible)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 4))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.red), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: px - 4, y: 0, width: 8, height: 8)), with: .color(.red))
        }
    }

    /// Each midnight in view, where one day becomes the next.
    func midnights(in visible: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        var out: [Date] = []
        var d = calendar.startOfDay(for: visible.lowerBound)
        while d <= visible.upperBound {
            if d > visible.lowerBound { out.append(d) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    /// Where the ruler's marks go: each midnight's capsule, and the "Recording starts" label.
    func rulerMarkRects(_ context: GraphicsContext, size: CGSize, visible: ClosedRange<Date>) -> [CGRect] {
        var rects = midnights(in: visible).map { midnight -> CGRect in
            let px = x(midnight, width: size.width, visible: visible)
            let box = context.resolve(Text(midnight.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption2.weight(.semibold))).measure(in: size)
            return CGRect(x: px - 1, y: 0, width: box.width + 12, height: box.height + 4)
        }
        if let first = timeline.firstRecording, visible.contains(first) {
            let px = x(first, width: size.width, visible: visible)
            let box = context.resolve(Text("\(Image(systemName: "flag.fill")) Recording starts")
                .font(.caption2.weight(.semibold))).measure(in: size)
            let midX = Self.startLabelX(line: px, width: box.width)
            rects.append(CGRect(x: midX - box.width / 2, y: 2, width: box.width, height: box.height))
        }
        return rects
    }

    /// On the ruler: each midnight as the new day's name in a capsule, and where recording begins.
    func drawRulerMarks(_ context: GraphicsContext, size: CGSize, visible: ClosedRange<Date>) {
        for midnight in midnights(in: visible) {
            let px = x(midnight, width: size.width, visible: visible)
            let label = context.resolve(Text(midnight.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.caption2.weight(.semibold)).foregroundStyle(.primary))
            let box = label.measure(in: size)
            let pill = CGRect(x: px - 1, y: 0, width: box.width + 12, height: box.height + 4)
            context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .style(.quaternary))
            context.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
            var line = Path()
            line.move(to: CGPoint(x: px, y: pill.maxY))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .style(.primary.opacity(0.45)), lineWidth: 1.5)
        }
        if let first = timeline.firstRecording, visible.contains(first) {
            let px = x(first, width: size.width, visible: visible)
            let label = context.resolve(Text("\(Image(systemName: "flag.fill")) Recording starts")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tint))
            let box = label.measure(in: size)
            context.draw(label, at: CGPoint(x: Self.startLabelX(line: px, width: box.width), y: box.height / 2 + 2))
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .style(.tint), lineWidth: 1.5)
        }
    }

    /// Where "Recording starts" goes: just before its line, or just after it where there's no room before
    /// (never across it, as pushing it in from the edge did).
    static func startLabelX(line px: Double, width: Double) -> Double {
        let before = px - width / 2 - 4
        return before - width / 2 >= 2 ? before : px + width / 2 + 4
    }

    /// A camera added after the others: its lane before then dimmed and hatched (as the whole timeline is before
    /// the first recording), and where it began marked "Doorbell added".
    func drawAdded(_ context: GraphicsContext, camera: Config.Camera, at added: Date, lane: CGRect, size: CGSize,
                   visible: ClosedRange<Date>) {
        guard added > visible.lowerBound else { return }
        let px = min(size.width, x(added, width: size.width, visible: visible))
        let area = CGRect(x: lane.minX, y: lane.minY, width: max(0, px - lane.minX), height: lane.height)
        var clipped = context
        clipped.clip(to: Path(roundedRect: lane, cornerRadius: 6))
        clipped.fill(Path(area), with: .style(.background.opacity(0.45)))
        var hatch = Path()
        var hx = area.minX - lane.height
        while hx < area.maxX {
            hatch.move(to: CGPoint(x: hx, y: lane.maxY))
            hatch.addLine(to: CGPoint(x: hx + lane.height, y: lane.minY))
            hx += 10
        }
        var inArea = clipped
        inArea.clip(to: Path(area))
        inArea.stroke(hatch, with: .style(.secondary.opacity(0.18)), lineWidth: 1)
        guard visible.contains(added) else { return }
        var line = Path()
        line.move(to: CGPoint(x: px, y: lane.minY))
        line.addLine(to: CGPoint(x: px, y: lane.maxY))
        context.stroke(line, with: .style(.tint), lineWidth: 1.5)
        // The label before the line, in the empty part of the lane; without room there, the line alone (past
        // it is the camera's recording, where the label couldn't be read).
        let label = context.resolve(Text("\(Image(systemName: "flag.fill")) \(camera.name) added")
            .font(.caption2.weight(.semibold)).foregroundStyle(.tint))
        let box = label.measure(in: size)
        let midX = px - box.width / 2 - 6
        if midX - box.width / 2 >= lane.minX + 2 { context.draw(label, at: CGPoint(x: midX, y: lane.midY)) }
    }

    /// Private stretches with their ends moved onto the recording beside them, where it stops or starts again
    /// within a minute and a half of the change.
    static func joined(_ spans: [ClosedRange<Date>], to coverage: [ClosedRange<Date>]) -> [ClosedRange<Date>] {
        let near: TimeInterval = 90
        return spans.map { span in
            let start = coverage.map(\.upperBound).filter { abs($0.timeIntervalSince(span.lowerBound)) <= near }
                .min { abs($0.timeIntervalSince(span.lowerBound)) < abs($1.timeIntervalSince(span.lowerBound)) } ?? span.lowerBound
            let end = coverage.map(\.lowerBound).filter { abs($0.timeIntervalSince(span.upperBound)) <= near }
                .min { abs($0.timeIntervalSince(span.upperBound)) < abs($1.timeIntervalSince(span.upperBound)) } ?? span.upperBound
            return start < end ? start ... end : span
        }
    }

    /// The lanes: what each camera recorded, its events, the future dimmed, and the playhead's line.
    /// - Parameters:
    ///   - now: the present as drawn (each frame when zoomed in, else each second).
    ///   - frame: the time of this frame, for catch-ups.
    func drawLanes(_ context: GraphicsContext, size: CGSize, visible: ClosedRange<Date>, now clockNow: Date, frame: Date) {
        /// What is recorded and being recorded, per lane: kept out of the future's dimming.
        var recorded: [Path] = []
        // Every other day faintly tinted, so the day under the pointer is clear at a glance.
        let calendar = Calendar.current
        var dayStart = calendar.startOfDay(for: visible.lowerBound)
        while dayStart < visible.upperBound {
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let index = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: dayStart).day ?? 0
            if index % 2 != 0 {
                let x0 = max(0, x(dayStart, width: size.width, visible: visible))
                let x1 = min(size.width, x(next, width: size.width, visible: visible))
                context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .style(.primary.opacity(0.035)))
            }
            dayStart = next
        }
        // With events, recording is the background they sit on, so it is drawn quieter.
        let withEvents = !timeline.events.isEmpty
        for (i, camera) in cameras.enumerated() {
            let lane = laneRect(i, width: size.width)
            let selected = camera.id == timeline.camera
            context.fill(Path(roundedRect: lane, cornerRadius: 6), with: .style(.quaternary.opacity(selected ? 1 : 0.6)))
            if let added = timeline.added(camera.id) { drawAdded(context, camera: camera, at: added, lane: lane, size: size, visible: visible) }
            // Being recorded now (not playable yet): drawn after the recording it continues, joined to it.
            let coverage = drawnCoverage(camera.id, at: frame)
            // Private stretches, reaching to the recording on either side (recording stops and starts again a
            // moment apart from the change), so the lane runs on through them without a break.
            let privateSpans = Self.joined(timeline.privateSpans[camera.id] ?? [], to: coverage)
            // While the bar catches up, the part being recorded starts where the bar has reached.
            let recordingNow = timeline.recordingNow(of: camera.id, now: timeline.isLive ? (head ?? clockNow) : clockNow)
                .map { now in (coverage.last.map { min($0.upperBound, now.lowerBound) } ?? now.lowerBound) ... now.upperBound }
            for range in coverage where range.upperBound > visible.lowerBound && range.lowerBound < visible.upperBound {
                let x0 = max(0, x(range.lowerBound, width: size.width, visible: visible))
                let x1 = min(size.width, x(range.upperBound, width: size.width, visible: visible))
                let bar = CGRect(x: x0, y: lane.minY, width: max(2, x1 - x0), height: lane.height)
                let strength = withEvents ? (selected ? 0.65 : 0.38) : (selected ? 0.85 : 0.45)
                // Square on the right where the part being recorded carries on from it; square on the left where
                // it begins the camera's recording, against the line that marks it ("Recording starts", "… added").
                let joined = recordingNow?.lowerBound == range.upperBound || privateSpans.contains { $0.lowerBound == range.upperBound }
                let opens = timeline.cameraStarts[camera.id].map { abs(range.lowerBound.timeIntervalSince($0)) < 1 } ?? false
                    || privateSpans.contains { $0.upperBound == range.lowerBound }
                let shape = Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(
                    topLeading: opens ? 0 : 6, bottomLeading: opens ? 0 : 6,
                    bottomTrailing: joined ? 0 : 6, topTrailing: joined ? 0 : 6))
                context.fill(shape, with: .style(.tint.opacity(strength)))
                if range.upperBound > clockNow.addingTimeInterval(-3600) { recorded.append(shape) }
            }
            // Being recorded now, not playable yet: lighter and hatched, up to the present. Square on the left,
            // where it joins the recording before it; rounded on the right, where the dimmed future (drawn below)
            // reaches in under its corners.
            if let now = recordingNow, now.upperBound > visible.lowerBound, now.lowerBound < visible.upperBound {
                let x0 = max(0, x(now.lowerBound, width: size.width, visible: visible))
                let x1 = min(size.width, x(now.upperBound, width: size.width, visible: visible))
                let bar = CGRect(x: x0, y: lane.minY, width: max(2, x1 - x0), height: lane.height)
                let shape = Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(
                    topLeading: 0, bottomLeading: 0, bottomTrailing: 6, topTrailing: 6))
                recorded.append(shape)
                context.fill(shape, with: .style(.tint.opacity(selected ? 0.3 : 0.18)))
                // The stripes keep to the time axis, so the edges move over them rather than dragging them along.
                var hatch = Path()
                let origin = x(timeline.day, width: size.width, visible: visible)
                var hx = bar.minX - bar.height - (bar.minX - origin).truncatingRemainder(dividingBy: 6)
                while hx < bar.maxX {
                    hatch.move(to: CGPoint(x: hx, y: bar.maxY))
                    hatch.addLine(to: CGPoint(x: hx + bar.height, y: bar.minY))
                    hx += 6
                }
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    layer.stroke(hatch, with: .style(.tint.opacity(selected ? 0.55 : 0.3)), lineWidth: 1.5)
                }
            }
            // Private: indigo, hatched (nothing recorded, by choice), with the word where there's room.
            for span in privateSpans where span.upperBound > visible.lowerBound && span.lowerBound < visible.upperBound {
                let x0 = max(0, x(span.lowerBound, width: size.width, visible: visible))
                let x1 = min(size.width, x(span.upperBound, width: size.width, visible: visible))
                let bar = CGRect(x: x0, y: lane.minY, width: max(2, x1 - x0), height: lane.height)
                // Square where it joins recording, rounded where it's the lane's end (still private now).
                let after = coverage.contains { $0.upperBound == span.lowerBound }
                let before = coverage.contains { $0.lowerBound == span.upperBound }
                let r = min(6, bar.width / 2)
                let shape = Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(
                    topLeading: after ? 0 : r, bottomLeading: after ? 0 : r, bottomTrailing: before ? 0 : r, topTrailing: before ? 0 : r))
                // Over the lane, not the recording that may show beside it within a segment's seconds: alike
                // however short.
                context.fill(shape, with: .style(.background))
                context.fill(shape, with: .style(.quaternary.opacity(selected ? 1 : 0.6)))
                context.fill(shape, with: .color(.indigo.opacity(selected ? 0.18 : 0.12)))
                if highlighted == "private-\(camera.id)-\(span.lowerBound.timeIntervalSince1970)" {
                    context.stroke(Path(roundedRect: bar.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5), with: .color(.primary), lineWidth: 1.5)
                }
                // The stripes keep to the time axis, so they don't slide as the view pans.
                var hatch = Path()
                let origin = x(timeline.day, width: size.width, visible: visible)
                var hx = bar.minX - bar.height - (bar.minX - origin).truncatingRemainder(dividingBy: 7)
                while hx < bar.maxX {
                    hatch.move(to: CGPoint(x: hx, y: bar.maxY))
                    hatch.addLine(to: CGPoint(x: hx + bar.height, y: bar.minY))
                    hx += 7
                }
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    layer.stroke(hatch, with: .color(.indigo.opacity(selected ? 0.6 : 0.4)), lineWidth: 1.5)
                }
                let label = context.resolve(Text("\(Image(systemName: "eye.slash.fill")) Private")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.indigo))
                let box = label.measure(in: size)
                if box.width + 16 < bar.width, box.height < bar.height {
                    let plate = CGRect(x: bar.minX + 6, y: bar.midY - box.height / 2 - 1, width: box.width + 8, height: box.height + 2)
                    context.fill(Path(roundedRect: plate, cornerRadius: 4), with: .style(.background.opacity(0.85)))
                    context.draw(label, at: CGPoint(x: plate.midX, y: plate.midY))
                }
            }
            // The hovered one last, on top of any it overlaps, so its outline is whole.
            let marks = timeline.shownEvents.filter { $0.camera == camera.id && $0.end > visible.lowerBound && $0.start < visible.upperBound }
            for event in marks.filter({ $0.id != highlighted }) + marks.filter({ $0.id == highlighted }) {
                let mark = markRect(event, width: size.width, visible: visible)
                let isHovered = highlighted == event.id
                context.fill(Path(roundedRect: mark, cornerRadius: min(4, mark.width / 2)),
                             with: .color(event.kind.color.opacity(isHovered ? 1 : selected ? 0.9 : 0.6)))
                if isHovered {
                    context.stroke(Path(roundedRect: mark.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5),
                                   with: .color(.primary), lineWidth: 1.5)
                }
                // Room for the symbol when zoomed in far enough.
                if mark.width > 22, mark.height >= 10 {
                    // As text, so the symbol keeps its own shape (a walking figure is taller than wide).
                    let symbol = context.resolve(Text(Image(systemName: event.kind.symbol))
                        .font(.system(size: min(11, mark.height - 2), weight: .semibold)).foregroundStyle(.white))
                    let box = symbol.measure(in: mark.size)
                    context.draw(symbol, at: CGPoint(x: mark.minX + 4 + box.width / 2, y: mark.midY))
                }
            }
        }

        // Midnights, through every lane.
        for midnight in midnights(in: visible) {
            let px = x(midnight, width: size.width, visible: visible)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .style(.primary.opacity(0.45)), lineWidth: 1.5)
        }

        // Before the first recording there is nothing: dimmed and hatched, with the start marked.
        if let first = timeline.firstRecording, first > visible.lowerBound {
            let px = min(size.width, x(first, width: size.width, visible: visible))
            let area = CGRect(x: 0, y: 0, width: px, height: size.height)
            context.fill(Path(area), with: .style(.background.opacity(0.6)))
            var hatch = Path()
            var hx = -size.height
            while hx < px {
                hatch.move(to: CGPoint(x: hx, y: size.height))
                hatch.addLine(to: CGPoint(x: hx + size.height, y: 0))
                hx += 10
            }
            var clipped = context
            clipped.clip(to: Path(area))
            clipped.stroke(hatch, with: .style(.secondary.opacity(0.18)), lineWidth: 1)
            if visible.contains(first) {
                var line = Path()
                line.move(to: CGPoint(x: px, y: 0))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: .style(.tint), lineWidth: 1.5)
            }
        }

        // The future, today, is dimmed: from a corner's width before the present, so the lane beside the hatched
        // part's rounded end is dimmed like the rest (no lighter notch); less what is recorded and being recorded,
        // which that corner's width can reach into when the hatched part is narrower (zoomed out, or just after
        // new minutes load).
        let now = timeline.isLive ? (head ?? clockNow) : clockNow
        if visible.contains(now) {
            let px = x(now, width: size.width, visible: visible) - 6
            var dim = Path(CGRect(x: px, y: 0, width: size.width - px, height: size.height))
            for shape in recorded { dim = dim.subtracting(shape) }
            context.fill(dim, with: .style(.background.opacity(0.5)))
        }

        if let head, visible.contains(head) {
            let px = x(head, width: size.width, visible: visible)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.red), lineWidth: 2)
        }
    }
}

/// The grip between the video and what is below it: drag to give the lanes more or less room, double-click
/// to go back to the automatic size.
struct SplitGrip: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(.secondary.opacity(hovering ? 0.8 : 0.4))
            .frame(width: hovering ? 54 : 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { onDrag($0.translation.height) }
                .onEnded { _ in onEnd() })
            .onTapGesture(count: 2, perform: onReset)
            .help("Drag to resize the timeline; double-click for the automatic size")
    }
}

/// Shows an AVPlayer's video, kept the size of the view.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerHost()
        view.wantsLayer = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(view.playerLayer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? PlayerHost)?.playerLayer.player = player
    }

    final class PlayerHost: NSView {
        let playerLayer = AVPlayerLayer()

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Show or hide each kind of event, with how many there are that day.
struct EventFilters: View {
    @Bindable var timeline: TimelineModel
    @Namespace private var glass

    /// Only kinds with events that day (a filter for nothing is noise).
    var kinds: [TimelineEvent.Kind] { timeline.kindsPresent.filter { k in timeline.dayEvents.contains { $0.kind == k } } }

    static let animation = Animation.snappy(duration: 0.35)

    var body: some View {
        HStack(spacing: 8) {
            // One glass surface: a chip coming or going grows out of (or into) its neighbours, which slide over
            // to make room or close the gap.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(kinds) { kind in
                        chip(kind)
                            .glassEffectID(kind, in: glass)
                            .transition(.blur.combined(with: .scale(scale: 0.85)).combined(with: .opacity))
                    }
                }
            }
            Spacer()
            Text("Click an event to play it · [ and ] jump between them")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .animation(Self.animation, value: kinds)
        .animation(Self.animation, value: timeline.dayEvents.count)
    }

    func chip(_ kind: TimelineEvent.Kind) -> some View {
        let count = timeline.dayEvents.count { $0.kind == kind }
        let on = timeline.shownKinds.contains(kind)
        return Button {
            withAnimation(Self.animation) {
                if on { timeline.shownKinds.remove(kind) } else { timeline.shownKinds.insert(kind) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(on ? kind.color : .secondary)
                Text(kind.title)
                // A count that changes rolls to its new number, the chip's width following.
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(count)))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .opacity(on ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(kind.color.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .help(on ? "Hide \(kind.title.lowercased()) events" : "Show \(kind.title.lowercased()) events")
    }
}

/// The event under the pointer, and the top centre of its mark in TimelineView's coordinate space.
struct EventHover: Equatable {
    var event: TimelineEvent
    var anchor: CGPoint
}

/// What happened, shown above an event's mark when hovering over it: a glass card with an arrow at `arrowX`.
struct EventCallout: View {
    let event: TimelineEvent
    let camera: String
    let arrowX: Double

    static let arrowSize = CGSize(width: 26, height: 10)

    /// "13 s", "12 min", "2 h 5 min".
    static func length(_ seconds: Double) -> String {
        switch seconds {
        case ..<90: "\(Int(seconds.rounded())) s"
        case ..<5400: "\(Int((seconds / 60).rounded())) min"
        default: "\(Int(seconds / 3600)) h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: event.kind.symbol).foregroundStyle(event.kind.color)
                Text(event.kind.title).font(.headline)
                Text("· \(camera)").foregroundStyle(.secondary)
            }
            // Read at once (and kept), not loaded after: the card has its final size from the first frame, so
            // moving between events slides it instead of flickering through a placeholder.
            if let picture = event.snapshot.flatMap(EventPictures.image) {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(event.summary).font(.callout).frame(maxWidth: 260, alignment: .leading)
            HStack(spacing: 4) {
                if event.kind == .privacy {
                    Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened)) · \(Self.length(event.seconds))")
                } else {
                    Text("\(event.start.formatted(date: .omitted, time: .standard)) · \(Int(event.seconds.rounded())) s")
                    Spacer(minLength: 16)
                    Text("Click to play")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .padding(.bottom, Self.arrowSize.height)
        .glassEffect(.regular, in: CalloutShape(arrowX: arrowX, arrow: Self.arrowSize, radius: 14))
    }
}

/// Events' pictures, read once and kept (small JPEGs; a few hundred at most in a session).
@MainActor
enum EventPictures {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(_ url: URL) -> NSImage? {
        if let kept = cache.object(forKey: url as NSURL) { return kept }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A rounded rectangle with an arrow growing out of its bottom edge at `arrowX`, as one outline, so glass
/// renders card and arrow as a single surface.
struct CalloutShape: Shape {
    var arrowX: Double
    var arrow: CGSize
    var radius: Double

    var animatableData: Double {
        get { arrowX }
        set { arrowX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = radius
        let base = rect.maxY - arrow.height
        let tip = rect.maxY
        let half = arrow.width / 2
        let x = rect.minX + min(max(arrowX, r + half), rect.width - r - half)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: base - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: base), tangent2End: CGPoint(x: rect.maxX - r, y: base), radius: r)
        // The arrow: flaring out of the edge, with a rounded tip.
        p.addLine(to: CGPoint(x: x + half, y: base))
        p.addCurve(to: CGPoint(x: x, y: tip),
                   control1: CGPoint(x: x + half * 0.45, y: base),
                   control2: CGPoint(x: x + half * 0.22, y: tip))
        p.addCurve(to: CGPoint(x: x - half, y: base),
                   control1: CGPoint(x: x - half * 0.22, y: tip),
                   control2: CGPoint(x: x - half * 0.45, y: base))
        p.addLine(to: CGPoint(x: rect.minX + r, y: base))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: base), tangent2End: CGPoint(x: rect.minX, y: base - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// On the video while an event is playing.
struct EventBadge: View {
    let event: TimelineEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind.symbol).foregroundStyle(event.kind.color)
            Text(event.kind.title).font(.headline)
            Text(event.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(.regular, in: .capsule)
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// Reports sideways scrolling (trackpad swipes, a mouse's horizontal wheel) while `active`, and keeps it from
/// the views underneath; mostly vertical scrolling passes on untouched.
struct HorizontalScroll: NSViewRepresentable {
    let active: Bool
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(active: active, onScroll: onScroll) }

    @MainActor
    final class Coordinator {
        var active: Bool
        var onScroll: (Double) -> Void
        private var monitor: Any?

        init(active: Bool, onScroll: @escaping (Double) -> Void) {
            self.active = active
            self.onScroll = onScroll
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.active, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
                self.onScroll(event.scrollingDeltaX * scale)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// A row of choices in a capsule, the chosen one in a glass capsule of its own that slides between them.
struct CapsuleSegments<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.callout.weight(chosen ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(chosen ? .primary : .secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(.white.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "chosen", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.18), in: Capsule())
        .fixedSize()
    }
}

/// The Mac's own calendar, without its box and background, so it sits on the popover's glass.
struct CalendarPicker: NSViewRepresentable {
    let date: Date
    let latest: Date
    let pick: (Date) -> Void

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.maxDate = latest
        picker.dateValue = date
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.pick = pick
        picker.maxDate = latest
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: date, pick: pick) }

    @MainActor
    final class Coordinator: NSObject {
        var pick: (Date) -> Void
        private var shown: Date

        init(date: Date, pick: @escaping (Date) -> Void) {
            shown = date
            self.pick = pick
        }

        @objc func changed(_ sender: NSDatePicker) {
            // The month arrows move the date by a month; clicking a day stays in the month shown. Only the
            // latter picks.
            let calendar = Calendar.current
            let sameMonth = calendar.isDate(sender.dateValue, equalTo: shown, toGranularity: .month)
            shown = sender.dateValue
            if sameMonth { pick(sender.dateValue) }
        }
    }
}

/// The selected camera live in the timeline's player: its main stream, as on the live view's stage.
struct TimelineLive: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    @State private var stream: LiveStream?

    var body: some View {
        content
            // The timeline's sound button rules the live sound too.
            .onChange(of: model.timeline.muted) { _, muted in stream?.muted = muted }
            .onChange(of: stream?.hasAudio ?? false, initial: true) { _, has in model.timeline.liveHasAudio = has }
    }

    var content: some View {
        ZStack {
            if let stream {
                VideoLayerView(layer: stream.layer).opacity(stream.state == .playing ? 1 : 0)
                if stream.state != .playing {
                    VStack(spacing: 10) {
                        if case let .failed(reason) = stream.state {
                            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Can\u{2019}t connect").font(.headline)
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                        } else if stream.state == .serviceStopped || stream.state == .serviceBehind,
                                  let starting = model.serviceStartingWords {
                            ProgressView().controlSize(.large)
                            Text(starting).font(.callout).foregroundStyle(.secondary)
                        } else if stream.state == .serviceStopped || stream.state == .serviceBehind {
                            let stopped = stream.state == .serviceStopped
                            Image(systemName: stopped ? "pause.circle" : "arrow.clockwise.circle")
                                .font(.largeTitle).foregroundStyle(.secondary)
                            Text(stopped ? "Service not running" : "Not live yet").font(.headline)
                            Text(stopped ? ServiceNote.stopped : ServiceNote.behind(camera.name))
                                .font(.callout).foregroundStyle(.secondary)
                            Button(stopped ? "Start Service" : "Restart Service") { model.startService() }
                                .buttonStyle(.glass)
                        } else if stream.state == .noPicture {
                            Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No picture").font(.headline)
                        } else {
                            ProgressView().controlSize(.large)
                        }
                    }
                    .environment(\.colorScheme, .dark)
                }
            } else {
                Text("No password for \(camera.name)").font(.headline).foregroundStyle(.secondary)
            }
        }
        .task {
            guard model.hasPassword(camera.id) else { return }
            let s = LiveStream(url: camera.main, relay: model.streamRelay)
            s.muted = model.timeline.muted
            stream = s
            s.start()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            s.stop()
        }
    }
}

/// "LIVE" on the timeline's player while it shows the camera live: solid red, with a pulsing dot.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            LiveDot(active: true, color: .white)
            Text("LIVE").font(.headline.weight(.heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.red))
    }
}

/// A dot that pulses while live (a ring swelling out of it and fading), and sits still otherwise.
struct LiveDot: View {
    let active: Bool
    var color: Color = .red
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background {
                if active {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .scaleEffect(pulse ? 2.2 : 1)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }
            }
    }
}

/// A borderless control that shows the pointer is over it: a soft capsule behind it on hover, darker while
/// pressed (the transport buttons, the day arrows).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(HoverHighlight(pressed: configuration.isPressed))
    }
}

struct HoverHighlight: ViewModifier {
    var pressed = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    /// Every highlight the same height (and at least as wide), whatever its label: a bigger symbol or a word
    /// would otherwise make its own taller or shorter than the rest.
    static let size = 32.0

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
            .background(Capsule().fill(.primary.opacity(!enabled ? 0 : pressed ? 0.3 : hovering ? 0.18 : 0)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// On the player while it is paused on the recordings' last frame: says so, with when they end; once more
/// has been recorded since, that it is ready, and play carries on from here.
struct EndOfRecording: View {
    let timeline: TimelineModel

    var body: some View {
        let ready = timeline.newerAvailable
        HStack(spacing: 12) {
            Image(systemName: ready ? "play.circle.fill" : "stop.circle.fill")
                .font(.title2)
                .foregroundStyle(ready ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(ready ? "New recording ready" : "End of recording").font(.headline)
                if let end = timeline.playhead {
                    let time = end.formatted(date: .omitted, time: .standard)
                    Text(ready ? "Press play to watch on from \(time)" : "The last frame, at \(time)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.25), value: ready)
    }
}
