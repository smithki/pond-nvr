// Playback of continuous recording, on a timeline without day edges: recordings and events are kept for the
// days around the visible part and loaded further as it is panned. Segments come from RecordingIndex; to play from a moment, up
// to half an hour of one camera's segments from there are laid end to end in an AVMutableComposition, at
// their recorded times, so gaps stay gaps and the player's clock maps straight back to wall time. Playing
// past the end of that window loads the next one.
//
// Live: the selected camera as it is now, with the playhead at the present; only ever chosen (LIVE, or L).
// Seeking anywhere leaves it. Playing recording stops at its end, however close to the present.
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

    let player = AVPlayer()
    /// Midnight, local time, of the day in the middle of the view.
    private(set) var day = Calendar.current.startOfDay(for: Date())
    var camera: String?
    var zoom = Zoom.day {
        didSet { if zoom != oldValue { panStart = nil } }
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
    /// The events in `loaded`, all kinds; `shown` filters them.
    private(set) var events: [TimelineEvent] = []
    /// The events of the day in the middle of the view.
    var dayEvents: [TimelineEvent] { events.filter { $0.start >= day && $0.start < dayEnd } }
    var shownKinds = Set(TimelineEvent.Kind.allCases)
    var shownEvents: [TimelineEvent] { events.filter { shownKinds.contains($0.kind) } }
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

    /// The composition loaded in the player: the camera, the wall time of its zero, and its extent.
    private var window: (camera: String, origin: Date, end: Date)?
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
                guard let self, let item = self.player.currentItem, ended == ObjectIdentifier(item) else { return }
                self.continueAfterWindow()
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
        let (found, starts) = await Task.detached {
            var out: [String: [RecordedSpan]] = [:]
            var starts: [String: Date] = [:]
            for c in cameras {
                out[c] = RecordingIndex.spans(base: base, camera: c, from: from, to: to)
                starts[c] = RecordingIndex.earliest(base: base, camera: c)
            }
            return (out, starts)
        }.value
        let first = starts.values.min()
        // Each camera's newest segment is listed as a nominal minute; its file may be shorter (cut at a
        // keyframe, or still being written). Its real length, so the bar shows only what can be played.
        var trimmed = found
        for (c, list) in found {
            guard let last = list.last else { continue }
            let duration = try? await AVURLAsset(url: URL(fileURLWithPath: last.path)).load(.duration)
            if let seconds = duration?.seconds, seconds > 0, last.start.addingTimeInterval(seconds) < last.end {
                trimmed[c]![list.count - 1] = RecordedSpan(path: last.path, start: last.start, end: last.start.addingTimeInterval(seconds))
            }
        }
        spans = trimmed
        firstRecording = first
        cameraStarts = starts
        coverage = trimmed.mapValues { RecordingIndex.coverage($0) }
        events = MockEvents.enabled ? Self.mockEvents(coverage: coverage, from: from, to: to) : []
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
                e.id += n * 100_000
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
        player.replaceCurrentItem(with: nil)
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
        player.replaceCurrentItem(with: nil)
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

    /// How long after its last recorded minute a camera still counts as recording: the minute being written
    /// is not in the index until it is finished, and the index is read again every 30 s.
    /// The newest indexed segment ends where the one being written (".partial", not indexed) began: at most
    /// about 68 s ago, plus up to 30 s until the index is read again. 150 s covers that with room to spare.
    static let recordingLag = 150.0

    /// What the camera is recording now and cannot be played yet: from the end of its latest recording to
    /// `now`, if that ended less than `recordingLag` ago (the minute being written is not in the index yet).
    func recordingNow(of id: String, now: Date = Date()) -> ClosedRange<Date>? {
        guard let last = coverage[id]?.last, last.upperBound < now,
              now.timeIntervalSince(last.upperBound) < Self.recordingLag else { return nil }
        return last.upperBound ... now
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

    /// Played up to `end` (while playing, or at the end): the newest segment's file has grown since it was
    /// measured, so the bar is drawn to here, never short of the playhead.
    private func reachedEnd(of camera: String, at end: Date) {
        guard var list = spans[camera], let last = list.last, last.end < end else { return }
        list[list.count - 1] = RecordedSpan(path: last.path, start: last.start, end: end)
        spans[camera] = list
        coverage[camera] = RecordingIndex.coverage(list)
    }

    /// The end of the selected camera's latest recording.
    var latestRecorded: Date? { camera.flatMap { spans[$0]?.last?.end } }

    // MARK: - Playing

    func seek(to time: Date) async {
        guard let camera else { return }
        leaveLive()
        atEnd = false
        let time = min(time, Date())
        if let window, window.camera == camera, time >= window.origin, time < window.end {
            playhead = time
            seeks += 1
            await player.seek(to: CMTime(seconds: time.timeIntervalSince(window.origin), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            seeks -= 1
            return
        }
        let all = (spans[camera] ?? []).filter { $0.seconds > 0 }
        // Into what is being recorded (not playable yet): the last frame there is, straight away.
        if let now = recordingNow(of: camera), now.contains(time), let last = all.last {
            await seek(to: last.end.addingTimeInterval(-0.1))
            return
        }
        guard let first = all.firstIndex(where: { $0.end > time }) else {
            playhead = time
            nothingRecorded = true
            window = nil
            player.replaceCurrentItem(with: nil)
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
            reachedEnd(of: camera, at: built.end)
        }
        window = (camera, chunk[0].start, built.end)
        seeks += 1
        player.replaceCurrentItem(with: AVPlayerItem(asset: built.composition))
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
        playhead = window.origin.addingTimeInterval(time.seconds)
        // Playing into what was being recorded when the bar was measured (the newest file has grown since):
        // what plays is recorded, so the bar keeps up with the playhead.
        if let playhead { reachedEnd(of: window.camera, at: playhead) }
        // Catching up to the present at more than 1×: real time from here.
        if playing, rate != 1, nearPresent { rate = 1 }
        // Playing past the edge of a panned view: follow the playhead again.
        if let playhead, panStart != nil, playing, !visible.contains(playhead) { panStart = nil }
        if let playhead, Calendar.current.startOfDay(for: playhead) != day, panStart == nil {
            day = Calendar.current.startOfDay(for: playhead)
            loadMoreIfNeeded()
        }
    }

    private func continueAfterWindow() {
        guard let window, playing else { return }
        // The end of the recording (no later recording to play on into): paused on its last frame, where it is.
        // (The newest segment's listed end can be later than its file's: only a segment starting after counts.)
        guard spans[window.camera]?.contains(where: { $0.start >= window.end.addingTimeInterval(-1) }) == true else {
            pause()
            atEnd = true
            reachedEnd(of: window.camera, at: window.end)
            return
        }
        Task { await seek(to: window.end.addingTimeInterval(0.01)) }
    }

    // MARK: - Composition

    /// The segments at their recorded offsets from the first one's start; a segment longer than the gap to
    /// the next is trimmed to it.
    nonisolated static func composition(_ spans: [RecordedSpan]) async -> (composition: AVComposition, end: Date)? {
        guard let origin = spans.first?.start else { return nil }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var audio: AVMutableCompositionTrack?
        var end = origin
        for (i, span) in spans.enumerated() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: span.path))
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            var length = duration.seconds
            if i + 1 < spans.count { length = min(length, spans[i + 1].start.timeIntervalSince(span.start)) }
            guard length > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 90000))
            let offset = CMTime(seconds: span.start.timeIntervalSince(origin), preferredTimescale: 90000)
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
