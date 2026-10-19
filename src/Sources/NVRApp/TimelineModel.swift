// Playback of continuous recording, on a timeline without day edges: recordings and events are kept for the
// days around the visible part and loaded further as it is panned. Segments come from RecordingIndex; to play from a moment, up
// to half an hour of one camera's segments from there are laid end to end in an AVMutableComposition, at
// their recorded times, so gaps stay gaps and the player's clock maps straight back to wall time. Playing
// past the end of that window loads the next one.
//
// The minute being written is played too, as far as it's written (its 2-second fragments are on disk as they
// come): playing into it, what's written since is queued after what's playing (an AVQueuePlayer, so it runs on
// without a stop), a few seconds behind the present.
//
// The bar's growing end has one owner: `live`, each camera's segment being written and how far (its file's last
// write), read every half second. It's drawn at the clock less the writing's smoothed lag, so it moves steadily,
// through new files, never back and never past the present. Nothing else (playback, the follower) moves it.
//
// Live: the selected camera as it is now, with the playhead at the present; only ever chosen (LIVE, or L).
// Seeking anywhere leaves it.
import AVFoundation
import NVRCore
import Observation
import Recorder

@MainActor
@Observable
final class TimelineModel {
    enum Zoom: Double, CaseIterable, Identifiable {
        case day = 86400, sixHours = 21600, hour = 3600, quarter = 900

        var id: Double { rawValue }

        var title: String {
            switch self {
            case .day: "24 h"
            case .sixHours: "6 h"
            case .hour: "1 h"
            case .quarter: "15 m"
            }
        }

        /// Seconds between labelled ticks, and between minor ticks.
        var ticks: (major: Double, minor: Double) {
            switch self {
            case .day: (3 * 3600, 3600)
            case .sixHours: (3600, 900)
            case .hour: (600, 60)
            case .quarter: (300, 60)
            }
        }
    }

    let player = AVQueuePlayer()
    /// Midnight, local time, of the day in the middle of the view.
    private(set) var day = Calendar.current.startOfDay(for: Date()) {
        didSet { if day != oldValue { deriveDay() } }
    }
    var camera: String?
    /// How much of the day shows; remembered.
    var zoom = UserDefaults.standard.object(forKey: "timelineZoom").flatMap { ($0 as? Double).flatMap(Zoom.init) } ?? .day {
        didSet {
            if zoom != oldValue { panStart = nil }
            UserDefaults.standard.set(zoom.rawValue, forKey: "timelineZoom")
        }
    }
    /// Where the visible part starts when panned by hand; nil follows the playhead.
    var panStart: Date?
    /// When the earliest recording of any camera starts: the timeline's beginning.
    private(set) var firstRecording: Date?
    /// When each camera's recordings begin (its first segment): where a camera added later starts.
    private(set) var cameraStarts: [String: Date] = [:]
    /// A camera that began recording after the timeline's beginning (more than a segment or two later), and
    /// when: marked on its lane as added then.
    func added(_ camera: String) -> Date? {
        guard let start = cameraStarts[camera], let first = firstRecording, start.timeIntervalSince(first) > 180 else { return nil }
        return start
    }
    /// The stretch of time whose recordings and events are loaded.
    private(set) var loaded: ClosedRange<Date>?
    private var loadingMore = false
    /// Each camera's recorded segments in `loaded`.
    private(set) var spans: [String: [RecordedSpan]] = [:]
    var coverage: [String: [ClosedRange<Date>]] = [:]
    /// The moment shown, while playing or paused.
    private(set) var playhead: Date? {
        didSet {
            let far = switch (oldValue, playhead) {
            case let (old?, new?): abs(new.timeIntervalSince(old)) > zoom.rawValue
            case (nil, nil): false
            default: true
            }
            if far { jumps += 1 }
        }
    }
    /// Counts the playhead's moves to somewhere out of view (another day, live from long ago, an event far
    /// off): the lanes cross-fade to those instead of gliding the whole way.
    private(set) var jumps = 0
    private(set) var playing = false
    /// Sound off, for recordings and live alike; off at first, as in the live view, and remembered.
    var muted = UserDefaults.standard.object(forKey: "timelineMuted") as? Bool ?? true {
        didSet {
            player.isMuted = muted
            UserDefaults.standard.set(muted, forKey: "timelineMuted")
        }
    }
    /// The recording in the player has sound.
    private(set) var recordingHasAudio = false
    /// The camera live has sound (its stream says so; set by the live picture).
    var liveHasAudio = false
    /// There is sound to hear now.
    var hasAudio: Bool { isLive ? liveHasAudio : recordingHasAudio }
    var rate: Float = 1 {
        didSet { if playing { player.rate = rate } }
    }
    /// Where events and private stretches are read from (set from the settings before loading).
    var source: EventSource?
    /// The events in `loaded`, all kinds; `shown` filters them. What's worked out from them (each camera's index,
    /// the shown ones, the day's) is worked out once as they change, not each time they're drawn.
    private(set) var events: [TimelineEvent] = [] {
        didSet { derive() }
    }
    /// Each camera's events by start, to find those in a stretch of time without looking at them all.
    @ObservationIgnored private(set) var index: [String: EventIndex] = [:]
    /// When each camera was private, in `loaded`, as read (up to when it was read).
    private(set) var privateSpans: [String: [ClosedRange<Date>]] = [:]
    private var privacyRead = Date.distantPast
    /// Finished segments' real lengths, as measured.
    private var measured: [String: Double] = [:]
    /// What each camera is recording now: the segment being written and how far (its file's last write), read
    /// every half second. The one thing the bar's growing end follows (nothing else moves it).
    private(set) var live: [String: LiveSegment] = [:]
    /// How far behind the present each camera's writing runs (smoothed over the reads): the bar's end is drawn that
    /// far behind the clock, so it moves with it, steadily, whatever the fragments' timing.
    @ObservationIgnored private var liveLag: [String: Double] = [:]
    /// Nothing written for this long: not recording now.
    static let liveTimeout = 15.0
    /// The edge is drawn on past what was last seen written by at most this (a fragment's length), as time passes,
    /// so it moves with the clock between reads instead of stepping.
    static let liveGlide = 2.5
    /// The cameras private now, and since when this app saw each become so (set from the app's privacy state):
    /// a stretch going on now is drawn up to the present, and one just begun at once, not at the next read.
    var privateNow: [String: Date] = [:]

    /// A camera's private stretches as they are now.
    func privateSpans(of camera: String, now: Date = Date()) -> [ClosedRange<Date>] {
        var spans = privateSpans[camera] ?? []
        guard let since = privateNow[camera] else { return spans }
        if let last = spans.last, abs(last.upperBound.timeIntervalSince(privacyRead)) < 2 || last.upperBound >= since {
            // Still going: on to now.
            spans[spans.count - 1] = last.lowerBound ... max(last.upperBound, now)
        } else if since < now {
            spans.append(since ... now)
        }
        return spans
    }
    /// The events of the day in the middle of the view, and how many of each kind.
    private(set) var dayEvents: [TimelineEvent] = []
    private(set) var dayCounts: [TimelineEvent.Kind: Int] = [:]
    /// The kinds with events that day, in order (the filters offered).
    var dayKinds: [TimelineEvent.Kind] { TimelineEvent.Kind.allCases.filter { (dayCounts[$0] ?? 0) > 0 } }
    var shownKinds = Set(TimelineEvent.Kind.allCases) {
        didSet { if shownKinds != oldValue { shownEvents = events.filter { shownKinds.contains($0.kind) } } }
    }
    private(set) var shownEvents: [TimelineEvent] = []

    private func derive() {
        index = Dictionary(grouping: events, by: \.camera).mapValues(EventIndex.init)
        shownEvents = events.filter { shownKinds.contains($0.kind) }
        deriveDay()
    }

    private func deriveDay() {
        let (start, end) = (day, dayEnd)
        dayEvents = events.filter { $0.start >= start && $0.start < end }
        dayCounts = dayEvents.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }
    /// Nothing is recorded at the playhead (or after it, that day).
    private(set) var nothingRecorded = false
    /// Paused on the last frame of the recordings, with nothing later to play: the player says so.
    private(set) var atEnd = false
    /// How far along the view the present is while live.
    static let liveAt = 0.85
    /// Showing the selected camera live: no recording plays, and the playhead keeps to the present.
    private(set) var isLive = false
    private var liveClock: Task<Void, Never>?
    private(set) var loading = false
    /// The time under the pointer while the lanes are scrubbed (the clock shows it), before it is let go.
    var scrubbing: Date?
    /// Player seeks under way: the playhead is where it was sent, not where the player last said it was.
    private var seeks = 0

    /// What's loaded in the player: the camera, the wall time of its first item's zero, and the end of its last.
    private var window: (camera: String, origin: Date, end: Date)?
    /// The player's items, in order: each one's wall time at its zero, and its end. One, unless the minute
    /// being written has been followed (each later item is what was written since the one before).
    private var queued: [(item: AVPlayerItem, origin: Date, end: Date)] = []
    /// Adds what's written since to the queue while playing into the minute being written.
    private var follower: Task<Void, Never>?
    /// Played to the end of what's written, waiting for the next fragment.
    private var waitingForMore = false
    private var generation = 0
    private var observer: Any?
    private var base = ""
    private var cameras: [String] = []

    var dayEnd: Date { day.addingTimeInterval(86400) }
    var isToday: Bool { Calendar.current.isDateInToday(day) }
    /// The latest the view can reach: the end of today.
    var horizon: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400) }

    init() {
        player.isMuted = muted
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let i = self.queued.firstIndex(where: { ObjectIdentifier($0.item) == ended }) else { return }
                // One of several queued: the player goes on to the next by itself.
                if i < self.queued.count - 1 {
                    self.queued.removeFirst(i + 1)
                    return
                }
                self.continueAfterWindow()
            }
        }
        // An item that can't be read on (its file gone from under it): built again from where it stopped.
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let failed = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.queued.contains(where: { ObjectIdentifier($0.item) == failed }),
                      let at = self.playhead else { return }
                let wasPlaying = self.playing
                Task {
                    await self.seek(to: at)
                    if wasPlaying { self.play() }
                }
            }
        }
    }

    /// The visible part: the zoom's length, centred on the playhead (or panned by hand), never past today.
    var visible: ClosedRange<Date> {
        let length = zoom.rawValue
        // Live: the present stays near the right, and the timeline moves under it as time goes on.
        if isLive, panStart == nil, let playhead {
            let start = playhead.addingTimeInterval(-length * Self.liveAt)
            return start ... start.addingTimeInterval(length)
        }
        let centre = playhead ?? (isToday ? Date() : day.addingTimeInterval(43200))
        let start = min(panStart ?? centre.addingTimeInterval(-length / 2), horizon.addingTimeInterval(-length))
        return start ... start.addingTimeInterval(length)
    }

    /// Moves the visible part by `seconds` (later when positive), across days as freely as within one: back to
    /// a little before the first recording, forward to the end of today.
    func pan(by seconds: TimeInterval) {
        let length = zoom.rawValue
        var start = min(visible.lowerBound.addingTimeInterval(seconds), horizon.addingTimeInterval(-length))
        if let firstRecording { start = max(start, firstRecording.addingTimeInterval(-length / 4)) }
        panStart = start
        let centre = visible.lowerBound.addingTimeInterval(length / 2)
        let middleDay = Calendar.current.startOfDay(for: centre)
        if middleDay != day { day = middleDay }
        loadMoreIfNeeded()
    }

    /// Loads the days around the view when it nears the edge of what is loaded.
    func loadMoreIfNeeded() {
        guard !loadingMore, let loaded else { return }
        let margin = zoom.rawValue
        let needed = visible.lowerBound.addingTimeInterval(-margin) ... visible.upperBound.addingTimeInterval(margin)
        guard needed.lowerBound < loaded.lowerBound || (needed.upperBound > loaded.upperBound && loaded.upperBound < horizon)
        else { return }
        loadingMore = true
        Task {
            await load(base: base, cameras: cameras)
            loadingMore = false
        }
    }

    // MARK: - Loading

    /// Reads the recordings of the days around the view (the day before it to the day after). Called
    /// again as the view moves, and to pick up new segments.
    func load(base: String, cameras: [String]) async {
        self.base = base
        self.cameras = cameras
        if camera == nil || !cameras.contains(camera!) { camera = cameras.first }
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: visible.lowerBound.addingTimeInterval(-86400))
        let to = min(horizon, calendar.startOfDay(for: visible.upperBound).addingTimeInterval(2 * 86400))
        let source = self.source
        let known = live.mapValues(\.path)
        let (found, starts, kept, privacy, writing) = await Task.detached {
            var out: [String: [RecordedSpan]] = [:]
            var starts: [String: Date] = [:]
            var writing: [String: LiveSegment] = [:]
            for c in cameras {
                out[c] = RecordingIndex.spans(base: base, camera: c, from: from, to: to, writing: true)
                starts[c] = RecordingIndex.earliest(base: base, camera: c)
                writing[c] = RecordingIndex.beingWritten(base: base, camera: c, known: known[c])
            }
            let events = (source?.events(from: from, to: to) ?? []).filter { cameras.contains($0.camera) }
            return (out, starts, events, source?.privateSpans(from: from, to: min(to, Date())) ?? [:], writing)
        }.value
        for (c, segment) in writing where Date().timeIntervalSince(segment.through) < Self.liveTimeout {
            live[c] = segment
        }
        for c in cameras where writing[c].map({ Date().timeIntervalSince($0.through) >= Self.liveTimeout }) ?? true { live[c] = nil }
        let first = starts.values.min()
        // Ends: the segment being written ends where it's written (its file's last write); a finished one the next
        // follows on from, at the next one's start; a finished one before a gap (the camera went private, or
        // dropped), where its video does: measured, once (finished files don't change).
        var trimmed = found
        for (c, list) in found {
            for (i, span) in list.enumerated() {
                if let segment = live[c], span.path == segment.path {
                    trimmed[c]![i] = RecordedSpan(path: span.path, start: span.start, end: segment.through)
                    continue
                }
                guard i == list.count - 1 || list[i + 1].start > span.end.addingTimeInterval(0.5) else { continue }
                if measured[span.path] == nil {
                    measured[span.path] = (try? await Self.asset(span.path).load(.duration).seconds) ?? 0
                }
                let seconds = measured[span.path] ?? 0
                if span.start.addingTimeInterval(seconds) < span.end {
                    trimmed[c]![i] = RecordedSpan(path: span.path, start: span.start, end: span.start.addingTimeInterval(seconds))
                }
            }
        }
        spans = trimmed
        firstRecording = first
        cameraStarts = starts
        coverage = trimmed.mapValues { RecordingIndex.coverage($0) }
        // (Only when they changed: a reload that found nothing new changes nothing, and draws nothing again.)
        let next = MockEvents.enabled ? Self.mockEvents(coverage: coverage, from: from, to: to) : kept
        if next != events { events = next }
        privateSpans = privacy
        privacyRead = min(to, Date())
        loaded = from ... to
    }

    /// Made-up events, day by day (each day's the same every time), numbered apart.
    static func mockEvents(coverage: [String: [ClosedRange<Date>]], from: Date, to: Date) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        var dayStart = from
        var n = 0
        while dayStart < to {
            let dayEnd = dayStart.addingTimeInterval(86400)
            let clipped = coverage.mapValues { ranges in
                ranges.compactMap { r -> ClosedRange<Date>? in
                    let lo = max(r.lowerBound, dayStart), hi = min(r.upperBound, dayEnd)
                    return lo < hi ? lo ... hi : nil
                }
            }
            out += MockEvents.make(coverage: clipped, day: dayStart).map { event in
                var e = event
                e.id = "\(n)-\(e.id)"
                return e
            }
            n += 1
            dayStart = dayEnd
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - Events

    /// Seconds of each event shown before it starts.
    static let preRoll = 3.0

    /// The selected camera's event at the playhead, if any.
    var currentEvent: TimelineEvent? {
        guard let playhead, let camera else { return nil }
        return shownEvents.last { $0.camera == camera && $0.start <= playhead && playhead < $0.end }
    }

    func play(_ event: TimelineEvent) async {
        if event.camera != camera {
            camera = event.camera
            window = nil
        }
        await seek(to: event.start.addingTimeInterval(-Self.preRoll))
        play()
    }

    /// The selected camera's next (or previous) shown event from the playhead.
    func jumpToEvent(forward: Bool) async {
        guard let camera else { return }
        let mine = shownEvents.filter { $0.camera == camera }
        let here = (playhead ?? day).addingTimeInterval(forward ? Self.preRoll + 0.5 : 0)
        let target = forward ? mine.first { $0.start > here }
                             : mine.last { $0.start.addingTimeInterval(-Self.preRoll) < here.addingTimeInterval(-1) }
        if let target { await play(target) }
    }

    func show(day newDay: Date) async {
        let start = Calendar.current.startOfDay(for: newDay)
        guard start != day else { return }
        leaveLive()
        pause()
        day = start
        panStart = nil
        playhead = nil
        window = nil
        clearQueue()
        await load(base: base, cameras: cameras)
        await showLatest()
    }

    /// Shows the last recorded moment of the day in view (today: about a minute ago), paused.
    func showLatest() async {
        guard let camera, let last = spans[camera]?.last(where: { $0.start < dayEnd }) else {
            nothingRecorded = true
            return
        }
        await seek(to: max(last.start, last.end.addingTimeInterval(-10)))
    }

    // MARK: - Live

    /// The selected camera live, the playhead at the present (today, followed as the clock runs).
    func goLive() {
        guard camera != nil else { return }
        pause()
        generation += 1
        window = nil
        clearQueue()
        loading = false
        nothingRecorded = false
        panStart = nil
        isLive = true
        atEnd = false
        rate = 1
        playhead = Date()
        let today = Calendar.current.startOfDay(for: Date())
        if day != today { day = today }
        loadMoreIfNeeded()
        liveClock?.cancel()
        liveClock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isLive else { return }
                self.playhead = Date()
                let today = Calendar.current.startOfDay(for: Date())
                if self.day != today, self.panStart == nil { self.day = today }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    private func leaveLive() {
        guard isLive else { return }
        isLive = false
        liveClock?.cancel()
        liveClock = nil
    }

    /// Near the present, playing faster than real time would run out of recording.
    static let recordingLag = 150.0

    /// Reads how far each camera's segment being written has got (its file's last write: cheap), and moves the
    /// bar's end there; a new segment begun (the last one finished) reads the folder again for it.
    func refreshLive() async {
        let base = self.base, cameras = self.cameras, known = live.mapValues(\.path)
        let now = Date()
        let read = await Task.detached {
            Dictionary(uniqueKeysWithValues: cameras.map { c in (c, RecordingIndex.beingWritten(base: base, camera: c, known: known[c], now: now)) })
        }.value
        var relist = false
        for c in cameras {
            let segment = read[c] ?? nil
            guard let segment, now.timeIntervalSince(segment.through) < Self.liveTimeout else {
                if live[c] != nil { live[c] = nil }
                continue
            }
            if let was = live[c], was.path != segment.path { relist = true }
            let sample = max(0, now.timeIntervalSince(segment.through))
            liveLag[c] = liveLag[c].map { $0 * 0.85 + sample * 0.15 } ?? sample
            if live[c] != segment {
                live[c] = segment
                setLiveEnd(of: c, segment)
            }
        }
        if relist { await load(base: base, cameras: cameras) }
    }

    /// The segment being written's span ends where it's written (added if it's newer than what's listed).
    private func setLiveEnd(of camera: String, _ segment: LiveSegment) {
        guard var list = spans[camera] else { return }
        if let i = list.lastIndex(where: { $0.path == segment.path }) {
            list[i] = RecordedSpan(path: segment.path, start: segment.start, end: segment.through)
        } else if list.last.map({ $0.start < segment.start }) ?? true {
            list.append(RecordedSpan(path: segment.path, start: segment.start, end: segment.through))
        } else {
            return
        }
        spans[camera] = list
        coverage[camera] = RecordingIndex.coverage(list)
    }

    /// Where the bar's growing end is drawn at `now`: the clock less the writing's lag (so it moves steadily),
    /// never further than a fragment past what's written (a camera that stops, stops it) nor past the present.
    /// Nil when the camera isn't recording.
    func liveEdge(of camera: String, now: Date) -> Date? {
        guard let segment = live[camera], now.timeIntervalSince(segment.through) < Self.liveTimeout else { return nil }
        let steady = now.addingTimeInterval(-(liveLag[camera] ?? 0))
        return max(segment.start, min(steady, segment.through.addingTimeInterval(Self.liveGlide), now))
    }

    /// What the camera is recording now and can't be played yet: from the bar's growing end to `now`.
    func recordingNow(of id: String, now: Date = Date()) -> ClosedRange<Date>? {
        guard let edge = liveEdge(of: id, now: now), edge < now else { return nil }
        return edge ... now
    }

    /// Live, or playing the last few minutes on the way to it: only real time makes sense (faster would run
    /// out of recording), so the speed is fixed at 1×.
    var nearPresent: Bool {
        isLive || playhead.map { Date().timeIntervalSince($0) < Self.recordingLag } ?? false
    }

    /// Paused at the end, and more has been recorded since (the newest segment grew, or a new one began).
    var newerAvailable: Bool {
        guard atEnd, let playhead, let latest = latestRecorded else { return false }
        return latest > playhead.addingTimeInterval(1)
    }

    /// The end of the selected camera's latest recording.
    var latestRecorded: Date? { camera.flatMap { spans[$0]?.last?.end } }

    // MARK: - Playing

    func seek(to time: Date) async {
        guard let camera else { return }
        leaveLive()
        atEnd = false
        let time = min(time, Date())
        if let window, window.camera == camera, let current = queued.first(where: { $0.item === player.currentItem }),
           time >= current.origin, time < current.end {
            playhead = time
            seeks += 1
            await player.seek(to: CMTime(seconds: time.timeIntervalSince(current.origin), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            seeks -= 1
            return
        }
        let all = (spans[camera] ?? []).filter { $0.seconds > 0 }
        // Past the newest recording, while the camera is recording (what's being written isn't playable yet) or
        // stopped just now: the last frame there is, straight away, paused there (live is only ever chosen), as at
        // the end of the recording.
        if let last = all.last, time >= last.end,
           live[camera] != nil || Date().timeIntervalSince(last.end) < Self.recordingLag {
            await seek(to: last.end.addingTimeInterval(-0.1))
            pause()
            atEnd = true
            return
        }
        guard let first = all.firstIndex(where: { $0.end > time }) else {
            playhead = time
            nothingRecorded = true
            window = nil
            clearQueue()
            pause()
            return
        }
        nothingRecorded = false
        var start = max(time, all[first].start)
        let chunk = Array(all[first...].prefix { $0.start < all[first].start.addingTimeInterval(1800) })
        generation += 1
        let mine = generation
        loading = true
        playhead = start
        guard let built = await Self.composition(chunk) else {
            loading = false
            return
        }
        guard mine == generation else { return }
        loading = false
        // Nothing to play from here: a segment's file can be shorter than its nominal minute (cut at a
        // keyframe, or still being written), so the moment asked for is past its end. Asking again would
        // rebuild the same empty stretch over and over; go on instead.
        if built.end.timeIntervalSince(start) < 0.5 {
            if let next = all.first(where: { $0.start > start.addingTimeInterval(0.5) }) {
                await seek(to: next.start)
                return
            }
            // The end of the recording: its last frame, paused (shown below, not asked for again).
            pause()
            start = max(chunk[0].start, built.end.addingTimeInterval(-0.1))
            playhead = start
            atEnd = true
        }
        window = (camera, chunk[0].start, built.end)
        seeks += 1
        clearQueue()
        let item = AVPlayerItem(asset: built.composition)
        player.insert(item, after: nil)
        queued = [(item, chunk[0].start, built.end)]
        follow()
        recordingHasAudio = !built.composition.tracks(withMediaType: .audio).isEmpty
        await player.seek(to: CMTime(seconds: start.timeIntervalSince(chunk[0].start), preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        seeks -= 1
        if playing { player.rate = rate }
    }

    func togglePlay() {
        if isLive {
            // Live does not pause: it becomes the latest recording, paused there.
            Task { await seek(to: (latestRecorded ?? Date()).addingTimeInterval(-2)) }
            return
        }
        if playing { pause() } else { play() }
    }

    func play() {
        // At the end: nothing to play, unless more has been recorded since; then on from here.
        if atEnd {
            guard newerAvailable, let from = playhead else { return }
            Task {
                await seek(to: from)
                play()
            }
            return
        }
        guard player.currentItem != nil else { return }
        playing = true
        player.rate = rate
    }

    func pause() {
        playing = false
        player.pause()
    }

    func skip(_ seconds: Double) async {
        if isLive {
            // Back from live: from the latest recording (what is being written now is not in it yet).
            guard seconds < 0 else { return }
            await seek(to: (latestRecorded ?? Date()).addingTimeInterval(seconds))
            play()
            return
        }
        guard let playhead else { return }
        await seek(to: playhead.addingTimeInterval(seconds))
    }

    /// Switches camera at the same moment.
    func select(camera id: String) async {
        guard id != camera else { return }
        camera = id
        window = nil
        if isLive { return }   // the new camera, live
        if let playhead { await seek(to: playhead) } else { await showLatest() }
    }

    private func tick(_ time: CMTime) {
        // Not while a seek is under way: the player still reports where it was (or the new clip's start), which
        // would pull the playhead back before it jumps on to where it was sent.
        guard let window, !loading, seeks == 0, time.isNumeric else { return }
        let origin = queued.first { $0.item === player.currentItem }?.origin ?? window.origin
        let before = playhead
        playhead = origin.addingTimeInterval(time.seconds)
        // Catching up to the present at more than 1×: real time from here.
        if playing, rate != 1, nearPresent { rate = 1 }
        // Playing past the edge of a panned view: follow the playhead again. Only as it crosses the edge (it was
        // in view a moment ago): a view panned away from it by hand stays where it was put.
        if let playhead, let before, panStart != nil, playing, visible.contains(before), playhead > visible.upperBound {
            panStart = nil
        }
        if let playhead, Calendar.current.startOfDay(for: playhead) != day, panStart == nil {
            day = Calendar.current.startOfDay(for: playhead)
            loadMoreIfNeeded()
        }
    }

    private func continueAfterWindow() {
        guard let window, playing else { return }
        // Played up to what's written of the minute being written: on as soon as the next fragment is (the
        // follower adds it), unless none comes.
        if live[window.camera] != nil, follower != nil {
            waitingForMore = true
            return
        }
        // The end of the recording (no later recording to play on into): paused on its last frame, where it is.
        // (The newest segment's listed end can be later than its file's: only a segment starting after counts.)
        guard spans[window.camera]?.contains(where: { $0.start >= window.end.addingTimeInterval(-1) }) == true else {
            pause()
            atEnd = true
            return
        }
        Task { await seek(to: window.end.addingTimeInterval(0.01)) }
    }

    // MARK: - Following the minute being written

    private func clearQueue() {
        follower?.cancel()
        follower = nil
        waitingForMore = false
        player.removeAllItems()
        queued = []
    }

    /// While playing into the minute being written, keeps a few seconds of it queued ahead of the playhead: what
    /// was written after the window's end, as an item of its own after the last. Stops when the window leaves it.
    private func follow() {
        follower?.cancel()
        guard let window, live[window.camera].map({ $0.start < window.end.addingTimeInterval(1) }) == true
        else { follower = nil; return }
        let camera = window.camera, base = self.base
        follower = Task { [weak self] in
            var idle = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let window = self.window, window.camera == camera else { return }
                // Enough queued ahead (or paused, with nothing used up): later.
                let ahead = window.end.timeIntervalSince(self.playhead ?? window.end)
                guard self.waitingForMore || (self.playing && ahead < Self.followAhead) else { continue }
                let found = await Task.detached {
                    RecordingIndex.spans(base: base, camera: camera, from: window.end.addingTimeInterval(-120),
                                         to: Date().addingTimeInterval(60), writing: true)
                }.value.filter { $0.end > window.end }
                guard !Task.isCancelled, let built = await Self.composition(found, from: window.end),
                      built.end.timeIntervalSince(window.end) >= 0.5, self.window?.end == window.end else {
                    // Nothing new: after a while waiting at the end, it's the end (the camera stopped).
                    if self.waitingForMore {
                        idle += 1
                        if idle >= Self.followPatience {
                            self.waitingForMore = false
                            self.pause()
                            self.atEnd = true
                            return
                        }
                    }
                    continue
                }
                idle = 0
                let item = AVPlayerItem(asset: built.composition)
                self.player.insert(item, after: self.queued.last?.item)
                self.queued.append((item, window.end, built.end))
                // (Playback only: the bar follows what's written, by its own reads.)
                self.window = (camera, window.origin, built.end)
                if self.waitingForMore {
                    // The last item had ended: on into this one.
                    self.waitingForMore = false
                    self.queued.removeAll { $0.item !== item }
                    self.player.advanceToNextItem()
                    if self.player.currentItem !== item { self.player.replaceCurrentItem(with: item) }
                    if self.playing { self.player.rate = self.rate }
                }
                // The minute being written finished and the next began: follow on into it.
                if found.last?.isBeingWritten != true { return }
            }
        }
    }

    /// Kept this far ahead of the playhead while following.
    static let followAhead = 6.0
    /// Seconds waited at the end of what's written for the next fragment before stopping there.
    static let followPatience = 8.0

    // MARK: - Composition

    /// A segment's file, readable while it's still being written (".mp4.partial" said to be MP4).
    nonisolated static func asset(_ path: String) -> AVURLAsset {
        AVURLAsset(url: URL(fileURLWithPath: path),
                   options: path.hasSuffix(".partial") ? [AVURLAssetOverrideMIMETypeKey: "video/mp4"] : nil)
    }

    /// The segments at their recorded offsets from the first one's start (or from `from`, what's before it
    /// left out); a segment longer than the gap to the next is trimmed to it.
    nonisolated static func composition(_ spans: [RecordedSpan], from: Date? = nil) async -> (composition: AVComposition, end: Date)? {
        guard let origin = from ?? spans.first?.start else { return nil }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var audio: AVMutableCompositionTrack?
        var end = origin
        for (i, span) in spans.enumerated() {
            let asset = Self.asset(span.path)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            var length = duration.seconds
            if i + 1 < spans.count { length = min(length, spans[i + 1].start.timeIntervalSince(span.start)) }
            // What's before the origin left out.
            let skip = max(0, origin.timeIntervalSince(span.start))
            guard length - skip > 0.05 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: skip, preferredTimescale: 90000),
                                    duration: CMTime(seconds: length - skip, preferredTimescale: 90000))
            let offset = CMTime(seconds: max(0, span.start.timeIntervalSince(origin)), preferredTimescale: 90000)
            insert(range, of: sourceVideo, into: video, at: offset)
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                if audio == nil {
                    audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audio { insert(range, of: sourceAudio, into: audio, at: offset) }
            }
            end = max(end, span.start.addingTimeInterval(length))
        }
        guard !video.segments.isEmpty else { return nil }
        return (composition, end)
    }

    nonisolated static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack,
                                   at offset: CMTime) {
        let trackEnd = track.timeRange.end
        var at = offset
        if track.segments.isEmpty || trackEnd < at {
            let from = track.segments.isEmpty ? .zero : trackEnd
            if from < at { track.insertEmptyTimeRange(CMTimeRange(start: from, end: at)) }
        } else {
            at = trackEnd   // rounding: never insert into what is already there
        }
        try? track.insertTimeRange(range, of: source, at: at)
    }
}
