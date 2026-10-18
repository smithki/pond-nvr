// Live: a rail of every camera (snapshots, in priority order) beside a stage showing the chosen ones live.
// Click a camera in the rail to add it to the stage or take it off; double-click it to watch it alone. The
// stage lays its tiles out as large as the window allows. Large tiles play the main stream, small ones the
// sub-stream.
import AVFoundation
import NVRCore
import SwiftUI

/// How the stage moves for a change.
enum StageMotion: Equatable {
    /// One change on its own: springy, rippling, new tiles popping in.
    case lively
    /// Changes in quick succession: calm, and tiles that change rows fade across.
    case calm
    /// Many cameras at once (Show All): a gentle, staggered fade in, no bounce.
    case reveal
    /// Cameras dragged into a new order: tiles slide straight to their places.
    case reorder
    /// One camera alone to another: no animation.
    case swap
    /// To one camera that was already on the stage: it grows to fill it, the others fade.
    case focus(String)
    /// To one camera that was not on the stage: the stage recedes and fades, the camera arrives.
    case crossfade
}

struct LiveView: View {
    @Environment(AppModel.self) private var model
    /// The cameras on the stage, comma-separated ids, kept between launches. Empty: the first four.
    @AppStorage("liveCameras") private var stagedIDs = ""
    /// The same, for this session: what the stage shows. Kept in view state, because a change to stored
    /// preferences can arrive as a separate update, after the animation meant for it.
    @State private var stagedList: [String]?
    @AppStorage(LiveView.railKey) private var showRail = true
    /// The rail as drawn: the stored preference, followed (it changes apart from the animation meant for it), or
    /// set here with the stage, so the rail coming back or stepping aside as one camera becomes several (or one)
    /// moves in the same animation as the tiles and the sidebar, not on its own a moment later.
    /// (Started from the preference, not left to fall back on it: falling back, a change of it was drawn at
    /// once, with nothing left for the animated following below to do.)
    @State private var railShown = UserDefaults.standard.object(forKey: LiveView.railKey) as? Bool ?? true
    /// The dock's adjustments shown (its stored preference), to bring their sidebar with the stage's change.
    @AppStorage(LiveControlsDock.adjustingKey) private var dockAdjusting = false
    private var railDrawn: Bool { railShown }
    /// The live controls dock is open under a camera watched on its own: kept between launches, and in view
    /// state for this session (a stored preference's change can arrive apart from the animation meant for it,
    /// and the dock and stage would then jump).
    @AppStorage("liveControls") private var controlsKept = false
    @State private var controlsShown: Bool?
    private var controlsWanted: Bool { controlsShown ?? controlsKept }
    /// The dock is shown once what's in it is known (a camera's positions, its night mode): opening before, it
    /// shifted as they arrived. Known once a session; switching cameras after, the dock stays open.
    @State private var dockReady = false
    /// The rail has just stepped aside for the controls: a note says so for a moment.
    @State private var railNote = false
    /// The live view's width (the rail, the stage and the adjustments' column).
    @State private var contentWidth: CGFloat = 0
    @AppStorage("liveRailWidth") private var railKeptWidth = CameraRail.defaultWidth
    @State private var railNoteTask: Task<Void, Never>?

    private var controlsOpen: Bool { controlsWanted && dockReady }
    @State private var snapshots = CameraSnapshots()
    @State private var activity = CameraActivity()
    private var reorderDrag: ReorderDrag { model.reorderDrag }
    /// The rail's order, held while a camera is dragged around the stage: the rail changes once, when the
    /// drag ends, rather than shuffling with every move on the stage.
    @State private var railOrder: [String]?
    /// The live status of each camera on the stage.
    @State private var liveStatus: [String: TileStatus] = [:]
    /// The camera just put on the stage, announced there for a moment.
    @State private var justAdded: String?
    @State private var announcement: Task<Void, Never>?
    /// The camera to announce when a quick run of changes is over.
    @State private var pendingAnnouncement: String?
    /// The last change took a camera off: the others then wait for it to fade before closing the gap.
    @State private var lastRemoved = false
    /// How the stage moves for the current change.
    @State private var motion = StageMotion.lively
    /// Cameras kept in front while others arrive (those already shown when Show All is clicked).
    @State private var inFront: Set<String> = []
    @State private var lastChange = Date.distantPast

    static let railKey = "liveRail"
    static let defaultCount = 4

    var body: some View {
        let cameras = model.config?.cameras ?? []
        Group {
            if cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras", systemImage: "video.slash")
                } description: {
                    Text("Add a camera by its address. Pond logs in, checks what it sends, and keeps the password in your Keychain.")
                } actions: {
                    Button("Add Camera…") { model.addingCamera = true }.buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    if railDrawn {
                        railView(cameras)
                            .transition(model.railMovesAtOnce ? .identity : .move(edge: .leading).combined(with: .opacity))
                    }
                    // The stage, and under it the controls of a camera watched on its own.
                    let docked = docked(cameras)
                    VStack(spacing: 0) {
                        Stage(cameras: cameras.filter { staged(cameras).contains($0.id) }, allCameras: cameras, snapshots: snapshots,
                              activity: activity, health: { health($0, cameras: cameras) }, openEvent: openEvent,
                              drag: reorderDrag, reorder: reorder,
                              justAdded: justAdded, afterRemoval: lastRemoved, motion: motion, inFront: inFront,
                              solo: solo, remove: { toggle($0) }, openControls: { openControls($0) })
                            // Above the dock: tiles growing back over its place (more cameras on the stage) pass
                            // over it as it goes, not under it.
                            .zIndex(1)
                        if let docked {
                            // The dock and its button, one piece: open, it sits under the stage with the button on
                            // its top edge; hidden, it slides down until only the button shows, at the bottom of
                            // the stage. Its place on the screen is only as tall as the dock while it's open.
                            Color.clear
                                .frame(height: controlsOpen ? Self.dockToggleRoom + 12 + LiveControlsDock.height() : 0)
                                .overlay(alignment: .top) {
                                    VStack(spacing: 8) {
                                        controlsButton
                                        // Centred, as wide as it needs (it lays itself out for narrower windows).
                                        LiveControlsDock(camera: docked.camera, controls: docked.controls, open: controlsOpen)
                                            .opacity(controlsOpen ? 1 : 0)
                                    }
                                    .padding(.horizontal, LiveLayout.dockInset)
                                    .offset(y: controlsOpen ? Self.dockToggleRoom - Self.controlsButtonHeight - 8
                                                            : -(Self.controlsButtonHeight + 14))
                                }
                                // Hidden, the button is over the stage; open, the stage is over the dock (tiles
                                // growing back over its place pass over it as it goes).
                                // (Above it too while a camera's other positions are open, reaching up over the stage.)
                                .zIndex(controlsOpen && model.morePositionsOpen == nil ? 0 : 2)
                                .transition(.opacity)
                        }
                    }
                    // The docked camera's adjustments, down the right as the rail is down the left: the picture
                    // keeps its height.
                    if let docked, controlsOpen, model.adjustmentsInSidebar, !model.sidebarFloats {
                        AdjustmentsView(camera: docked.camera, controls: docked.controls)
                            .frame(width: LiveLayout.sidebarWidth)
                            .background(.quaternary.opacity(0.35), in: LiveLayout.panel(nearWindowCorner: .bottomTrailing))
                            .padding(.trailing, LiveLayout.sidebarInset)
                            .padding(.vertical, 12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // What the dock will hold, asked before it opens (so it opens complete, then slides up); a slow
                // camera (logging in, busy) holds it back only a moment, then it opens and fills in.
                .task(id: docked(cameras)?.camera.id) {
                    guard !dockReady, let docked = docked(cameras) else { return }
                    model.loadPresetPictures(docked.camera.id, AppModel.keptPresets(docked.camera.id))
                    let camera = docked.camera.id
                    @MainActor func ready() {
                        guard !dockReady, self.docked(cameras)?.camera.id == camera else { return }
                        withAnimation(Self.dockAnimation) {
                            dockReady = true
                            // The adjustments' sidebar comes with it: the rail steps aside in the same motion if
                            // there isn't room for both (else the dock's own check moved it a moment later).
                            if controlsWanted, model.adjustmentsInSidebar, !model.sidebarFloats, railDrawn,
                               !railFitsBesideSidebar {
                                setRail(false)
                                model.railMadeRoom = true
                            }
                        }
                    }
                    // Whichever is first: loaded, or waited long enough (the loading goes on either way).
                    let loading = Task {
                        if (docked.controls.ptz?.presets ?? 0) > 0 { await model.loadPresets(camera) }
                        if !docked.controls.items.isEmpty { await model.loadItemValues(camera) }
                        if !Task.isCancelled { ready() }
                    }
                    do {
                        try await Task.sleep(for: .seconds(Self.dockWait))
                    } catch {
                        loading.cancel()
                        return
                    }
                    ready()
                }
                // ⌥⌘L: a camera's controls, watching it on its own if others are on the stage too.
                .background {
                    Button("Live Controls") { shortcut(cameras) }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        .hidden()
                }
                // The preference changed elsewhere (the toolbar, the dock making room): followed, sliding (or at once,
                // as the window is resized).
                .onChange(of: showRail) { _, shown in
                    guard railDrawn != shown else { return }
                    if model.railMovesAtOnce {
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { railShown = shown }
                    } else {
                        withAnimation(Self.panelAnimation) { railShown = shown }
                    }
                }
                // Whether the adjustments fit beside the stage (the rail out of the way if need be) or float over it.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    contentWidth = $0
                    if abs(model.liveWidth - $0) > 0.5 { model.liveWidth = $0 }
                }
                .onChange(of: contentWidth - LiveLayout.stageMargins - LiveLayout.sidebarRoom < model.dockNarrowest, initial: true) { _, floats in
                    // At once, not animated: the window is being resized (the adjustments moving between the sidebar
                    // and the dock's second frame, animated, were seen twice, leaving and arriving).
                    guard model.sidebarFloats != floats else { return }
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { model.sidebarFloats = floats }
                }
                // The rail stepped aside for the controls: said for a moment, where it was, then gone.
                .overlay(alignment: .topLeading) {
                    Label("Cameras hidden to make room for the controls", systemImage: "sidebar.leading")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                        .padding(14)
                        .opacity(railNote ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: railNote)
                        .allowsHitTesting(false)
                }
                .onChange(of: model.railMadeRoom) { _, madeRoom in
                    railNoteTask?.cancel()
                    railNote = madeRoom
                    guard madeRoom else { return }
                    railNoteTask = Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if !Task.isCancelled { railNote = false }
                    }
                }
                // Shown again by hand: no longer hidden for the sidebar's sake.
                .onChange(of: showRail) { _, shown in if shown { model.railMadeRoom = false } }
                // Whether the rail would fit beside the open controls, for the toolbar's button.
                .onChange(of: railFits(cameras), initial: true) { _, fits in if model.railFits != fits { model.railFits = fits } }
                .onPreferenceChange(TileStatuses.self) { liveStatus = $0 }
                .onChange(of: reorderDrag.camera) { _, dragged in
                    if dragged != nil, reorderDrag.source == .stage {
                        if railOrder == nil { railOrder = cameras.map(\.id) }
                    } else if dragged != nil, reorderDrag.source == .settings {
                        // Dragged in Settings: the tiles here slide as they do for a drag on the stage.
                        motion = .reorder
                    } else if dragged == nil, railOrder != nil {
                        withAnimation(.snappy(duration: 0.35)) { railOrder = nil }
                    }
                    // The drag is over: the next change moves as usual, not as a reorder.
                    if dragged == nil, motion == .reorder { motion = .lively }
                }
            }
        }
        .task(id: cameras.map(\.id)) {
            let base = model.config?.storage.recordingsPath ?? ""
            while !Task.isCancelled {
                await snapshots.refresh(base: base, cameras: cameras.map(\.id))
                await activity.refresh(base: base, cameras: cameras.map(\.id))
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// How a camera is doing. Staleness of recordings counts while the recorder runs; in the mock (where
    /// nothing records), against the newest recording of any camera, so a camera that stopped stands out.
    func health(_ id: String, cameras: [Config.Camera]) -> CameraHealth {
        if model.isPrivate(id) { return .keptPrivate }
        let asOf: Date? = model.isRecording ? Date()
            : MockEvents.enabled ? cameras.compactMap { snapshots[$0.id]?.time }.max() : nil
        return CameraHealth.of(live: staged(cameras).contains(id) ? liveStatus[id] : nil,
                               lastRecorded: snapshots[id]?.time, recordingAsOf: asOf,
                               startedRecording: model.recordingStarted[id])
    }

    static let dockAnimation = Animation.spring(duration: 0.42, bounce: 0.12)
    /// The side panels (the cameras' rail, the adjustments' sidebar) coming and going: one timing for both, the
    /// dock's, since they often move with it.
    static let panelAnimation = dockAnimation
    /// Above the dock: room for the button that shows and hides it.
    static let dockToggleRoom: CGFloat = 52
    /// The longest the dock waits for what it holds before opening.
    static let dockWait = 0.8
    /// The show and hide button's height (a large glass capsule).
    static let controlsButtonHeight: CGFloat = 36

    /// Shows or hides the controls.
    var controlsButton: some View {
        // Asked for and still being filled, it says so (a second click isn't taken for "hide").
        let opening = controlsWanted && !dockReady
        return Button { setControls(open: !controlsWanted) } label: {
            HStack(spacing: 6) {
                Label(controlsOpen ? "Hide Controls" : "Controls", systemImage: controlsOpen ? "chevron.down" : "chevron.up")
                    .contentTransition(.symbolEffect(.replace))
                if opening { ProgressView().controlSize(.mini) }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 6)
        }
        .disabled(opening)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .help(controlsOpen ? "Hide the controls (\u{2325}\u{2318}L)" : "Show this camera\u{2019}s controls (\u{2325}\u{2318}L)")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.controlsButtonWidth = $0 }
    }

    /// The cameras' rail.
    func railView(_ cameras: [Config.Camera]) -> some View {
        CameraRail(cameras: railOrder.map { order in order.compactMap { id in cameras.first { $0.id == id } } } ?? cameras,
                   staged: staged(cameras), snapshots: snapshots,
                   health: { health($0, cameras: cameras) },
                   solo: solo, toggle: toggle, showAll: { showAll(cameras.map(\.id)) },
                   openControls: { openControls($0) },
                   drag: reorderDrag, reorder: reorder)
    }

    /// The rail would fit beside the stage with the open controls at their narrowest (and the adjustments,
    /// beside the stage): its width as kept, whether it's shown or not.
    func railFits(_ cameras: [Config.Camera]) -> Bool {
        guard docked(cameras) != nil, controlsOpen else { return true }
        let sidebar = model.adjustmentsInSidebar && !model.sidebarFloats ? LiveLayout.sidebarRoom : 0
        let rail = LiveLayout.railRoom(railKeptWidth)
        return contentWidth - rail - LiveLayout.stageMargins - sidebar >= model.dockNarrowest
    }

    /// The camera whose controls go under the stage: the one watched on its own. Every camera has some (a
    /// picture of it, its privacy), besides what it can be controlled with.
    func docked(_ cameras: [Config.Camera]) -> (camera: Config.Camera, controls: Config.Controls)? {
        let ids = staged(cameras)
        guard ids.count == 1, let camera = cameras.first(where: { $0.id == ids[0] }) else { return nil }
        return (camera, model.controls(for: camera) ?? Config.Controls())
    }

    func setControls(open: Bool) {
        withAnimation(Self.dockAnimation) { controlsShown = open }
        controlsKept = open
    }

    /// Watches the camera on its own, with its controls open.
    func openControls(_ id: String) {
        solo(id)
        setControls(open: true)
    }

    /// The shortcut: shows or hides the controls of the camera watched on its own; with several on the stage,
    /// the first that can be moved or adjusted (else the first) is watched on its own with them open.
    func shortcut(_ cameras: [Config.Camera]) {
        if docked(cameras) != nil { return setControls(open: !controlsWanted) }
        let ids = staged(cameras)
        guard let id = ids.first(where: { id in
            cameras.first { $0.id == id }.flatMap { model.controls(for: $0) }.map { $0.ptz != nil || !$0.items.isEmpty } == true
        }) ?? ids.first else { return }
        openControls(id)
    }

    /// Shows a camera's latest event on the timeline.
    func openEvent(_ event: TimelineEvent) {
        model.timelineJump = TimelineJump(camera: event.camera, time: event.start)
        model.mode = .timeline
    }

    /// The staged cameras that still exist, in priority order; the first few if none are chosen.
    func staged(_ cameras: [Config.Camera]) -> [String] {
        let chosen = Set(stagedList ?? stagedIDs.split(separator: ",").map(String.init))
        let kept = cameras.map(\.id).filter { chosen.contains($0) }
        return kept.isEmpty ? Array(cameras.map(\.id).prefix(Self.defaultCount)) : kept
    }

    static let layoutAnimation = Animation.spring(duration: 0.5, bounce: 0.3)
    /// For changes in quick succession: no overshoot, no ripple, quickly done.
    static let calmAnimation = Animation.spring(duration: 0.46, bounce: 0.15)
    /// A change within this many seconds of the last one is part of a quick run of changes.
    static let fastPace = 0.45
    /// Tiles moving when many arrive at once.
    static let revealAnimation = Animation.smooth(duration: 0.4)
    /// One tile growing to fill the stage.
    static let focusAnimation = Animation.smooth(duration: 0.4)
    /// The stage receding and fading as another camera takes it over.
    static let recedeAnimation = Animation.smooth(duration: 0.25)
    /// When the new camera starts to arrive: as the old stage is nearly gone, so the two barely overlap.
    static let arriveDelay = 0.2
    /// How far the stage recedes, and the new camera grows from.
    static let recedeScale = 0.98

    func stage(_ ids: [String]) {
        withAnimation(motion == .calm ? Self.calmAnimation : Self.layoutAnimation) {
            alongStage(next: ids)
            stagedList = ids
        }
        stagedIDs = ids.joined(separator: ",")
    }

    /// The rail drawn (and kept so), in the current transaction.
    func setRail(_ shown: Bool) {
        railShown = shown
        if showRail != shown { showRail = shown }
    }

    /// The rail and the adjustments' sidebar for the stage about to be shown, in the same transaction as the
    /// stage's change, so they move with the tiles (and the dock coming or going), not on their own a moment later
    /// (the stage's width changing then, mid-move, the tiles were sent on at once):
    /// - one camera becoming several: the dock goes, so a rail that stepped aside for it comes back;
    /// - several becoming one with its controls open: its adjustments' sidebar comes (if they're shown and it has
    ///   some; the dock, new, would bring it only after it appeared, at once), and the rail steps aside if there
    ///   isn't room for it beside them.
    func alongStage(next ids: [String]) {
        let cameras = model.config?.cameras ?? []
        let now = staged(cameras).count
        if ids.count > 1, now == 1, model.railMadeRoom, !railDrawn {
            setRail(true)
            model.railMadeRoom = false
        } else if ids.count == 1, now > 1, controlsOpen, let camera = cameras.first(where: { $0.id == ids[0] }) {
            let adjustments = !DockContents.adjustments(model.controls(for: camera) ?? Config.Controls()).isEmpty
            if dockAdjusting, adjustments, !model.sidebarFloats, !model.adjustmentsInSidebar { model.adjustmentsInSidebar = true }
            if model.adjustmentsInSidebar, !model.sidebarFloats, railDrawn, !railFitsBesideSidebar {
                setRail(false)
                model.railMadeRoom = true
            }
        }
    }

    /// The rail, the stage at its margins, the sidebar and the narrowest dock fit across the window.
    var railFitsBesideSidebar: Bool {
        contentWidth - LiveLayout.railRoom(railKeptWidth) - LiveLayout.stageMargins - LiveLayout.sidebarRoom >= model.dockNarrowest
    }

    /// Moves a dragged camera to another's place in the order (its priority, saved in the settings), the
    /// rail and the stage making way as it goes.
    func reorder(_ id: String, onto target: String) {
        motion = .reorder
        withAnimation(.snappy(duration: 0.3)) { model.moveCamera(id, onto: target) }
    }

    /// Every camera on the stage, gently.
    func showAll(_ ids: [String]) {
        announcement?.cancel()
        pendingAnnouncement = nil
        justAdded = nil
        lastRemoved = false
        lastChange = .distantPast
        motion = .reveal
        inFront = Set(staged(model.config?.cameras ?? []))
        // As for solo: the motion first, then the change.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(Self.revealAnimation) {
                alongStage(next: ids)
                stagedList = ids
            }
            stagedIDs = ids.joined(separator: ",")
            try? await Task.sleep(for: .seconds(0.8))
            inFront = []
        }
    }

    /// Shows one camera alone: instantly from another single camera; from a multi-view, by growing it to
    /// fill the stage while the others fade (or a crossfade, when it was not on the stage).
    func solo(_ id: String) {
        let before = staged(model.config?.cameras ?? [])
        guard before != [id] else { return }
        announcement?.cancel()
        pendingAnnouncement = nil
        justAdded = nil
        lastRemoved = false
        lastChange = .distantPast
        let next: StageMotion = before.count == 1 ? .swap : before.contains(id) ? .focus(id) : .crossfade
        // The motion first, in its own update: a removed tile leaves with the transition it was last drawn
        // with, so the tiles must be drawn with this one before they go.
        motion = next
        Task { @MainActor in
            // A frame for the tiles to be drawn with their new way of leaving.
            try? await Task.sleep(for: .milliseconds(16))
            switch next {
            case .swap:
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { stagedList = [id] }
            case .focus:
                withAnimation(Self.focusAnimation) {
                    alongStage(next: [id])
                    stagedList = [id]
                }
            default:
                withAnimation(Self.recedeAnimation) {
                    alongStage(next: [id])
                    stagedList = [id]
                }
            }
            stagedIDs = id
        }
    }

    /// Adds a camera to the stage, or takes it off (keeping at least one).
    func toggle(_ id: String) {
        let now = Date()
        motion = now.timeIntervalSince(lastChange) < Self.fastPace ? .calm : .lively
        lastChange = now
        var ids = staged(model.config?.cameras ?? [])
        if let i = ids.firstIndex(of: id) {
            guard ids.count > 1 else { return }
            ids.remove(at: i)
            lastRemoved = true
            if motion == .calm { announceLater(nil) }
        } else {
            ids.append(id)
            lastRemoved = false
            if motion == .calm { announceLater(id) } else { announce(id) }
        }
        stage(ids)
    }

    /// In a quick run of changes, one announcement once it is over, for the last camera added (if it is
    /// still on the stage), rather than one glow after another.
    func announceLater(_ id: String?) {
        announcement?.cancel()
        let candidate = id ?? pendingAnnouncement
        pendingAnnouncement = candidate
        justAdded = nil
        announcement = Task {
            try? await Task.sleep(for: .seconds(Self.fastPace))
            guard !Task.isCancelled, let candidate, staged(model.config?.cameras ?? []).contains(candidate) else { return }
            pendingAnnouncement = nil
            motion = .lively
            announce(candidate)
        }
    }

    func announce(_ id: String) {
        announcement?.cancel()
        justAdded = id
        announcement = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            justAdded = nil
        }
    }
}

// MARK: - Rail

/// Every camera as a snapshot, in priority order, scrolling. Drag its edge to resize it: wide enough, the
/// snapshots go two to a row (never more columns than cameras).
struct CameraRail: View {
    let cameras: [Config.Camera]
    let staged: [String]
    let snapshots: CameraSnapshots
    let health: (String) -> CameraHealth
    let solo: (String) -> Void
    let toggle: (String) -> Void
    let showAll: () -> Void
    /// Watches a camera on its own with its controls open.
    var openControls: (String) -> Void = { _ in }
    let drag: ReorderDrag
    let reorder: (String, String) -> Void
    @AppStorage("liveRailWidth") private var width = CameraRail.defaultWidth
    @State private var dragStart: Double?
    @Environment(AppModel.self) private var model

    static let defaultWidth = 220.0
    static let widths = 180.0 ... 460.0
    /// The narrowest a snapshot gets before the rail goes back to one column.
    static let thumbnailWidth = 150.0

    /// As many columns of at least `thumbnailWidth` as fit, but no more than there are cameras: a single
    /// camera in a wide rail gets the whole width rather than half of it.
    var columns: Int {
        let inner = width.clamped(to: Self.widths) - 24
        let fit = max(1, Int((inner + 10) / (Self.thumbnailWidth + 10)))
        return min(fit, max(1, cameras.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            // On a narrow rail the count gives way, so "Show All" stays on one line.
            ViewThatFits(in: .horizontal) {
                header(count: true, title: true)
                header(count: false, title: true)
                header(count: false, title: false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns),
                          spacing: 10) {
                    ForEach(cameras) { camera in
                        RailThumbnail(camera: camera, snapshot: snapshots[camera.id], health: health(camera.id),
                                      onStage: staged.contains(camera.id),
                                      canRemove: staged.count > 1, solo: { solo(camera.id) }, toggle: { toggle(camera.id) },
                                      openControls: { openControls(camera.id) })
                            .reorderable(camera.id, name: camera.name, drag: drag, from: .rail, move: reorder)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)

            ViewThatFits(in: .horizontal) {
                Text("Click to add or remove · drag to reorder")
                VStack(spacing: 2) {
                    Text("Click to add or remove")
                    Text("Drag to reorder")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: width.clamped(to: Self.widths))
        .background(.quaternary.opacity(0.35), in: LiveLayout.panel(nearWindowCorner: .bottomLeading))
        .overlay(alignment: .trailing) {
            ResizeHandle { dx in
                let start = dragStart ?? width
                dragStart = start
                // No wider than leaves the open controls room.
                let widest = max(Self.widths.lowerBound, min(Self.widths.upperBound, model.railLimit ?? .infinity))
                width = (start + dx).clamped(to: Self.widths.lowerBound ... widest)
            } onEnd: {
                dragStart = nil
            } onReset: {
                withAnimation(.snappy(duration: 0.25)) { width = Self.defaultWidth }
            }
            // Centred in the gap between the rail and the stage, clear of both.
            .offset(x: 16)
        }
        .padding([.leading, .vertical], LiveLayout.railLeading)
        .padding(.trailing, LiveLayout.railTrailing)
    }
}

extension CameraRail {
    func header(count: Bool, title: Bool) -> some View {
        HStack {
            Text("Cameras").font(.headline)
            if count {
                Text("\(staged.count) of \(cameras.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ShowAllButton(allShown: staged.count == cameras.count, title: title, action: showAll)
        }
        .lineLimit(1)
    }
}

/// Puts every camera on the stage. While they all are, it shows so: tinted, with a checkmark that morphs in
/// from the grid symbol, and it does nothing when clicked.
struct ShowAllButton: View {
    let allShown: Bool
    /// Room for the words; otherwise the symbol alone.
    let title: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if !allShown { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: allShown ? "checkmark" : "square.grid.2x2")
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce, value: allShown)
                    .fontWeight(.semibold)
                if title { Text(allShown ? "All Shown" : "Show All") .contentTransition(.interpolate) }
            }
            .font(.callout)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(allShown ? .accentColor : nil)
        .controlSize(.small)
        .focusEffectDisabled()
        .animation(.snappy(duration: 0.25), value: allShown)
        .help(allShown ? "Every camera is on the screen" : "Put every camera on the screen")
        .accessibilityLabel(allShown ? "All cameras shown" : "Show all cameras")
    }
}

/// The rail's edge: drag to resize, double-click to go back to the usual width.
struct ResizeHandle: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(.secondary.opacity(hovering || dragging ? 0.8 : 0.4))
                .frame(width: 5, height: hovering || dragging ? 54 : 40)
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.15), value: hovering || dragging)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                dragging = true
                onDrag(value.translation.width)
            }
            .onEnded { _ in
                dragging = false
                onEnd()
            })
        .onTapGesture(count: 2, perform: onReset)
        .help("Drag to resize the list of cameras; double-click for the usual width")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

struct RailThumbnail: View {
    let camera: Config.Camera
    let snapshot: CameraSnapshots.Snapshot?
    let health: CameraHealth
    let onStage: Bool
    let canRemove: Bool
    let solo: () -> Void
    let toggle: () -> Void
    var openControls: () -> Void = {}
    @State private var hovering = false
    @State private var presses = 0
    /// What a click is about to do, shown at once while the stage waits to see whether it is the first click
    /// of a double-click.
    @State private var provisional: Bool?
    @State private var pending: Task<Void, Never>?

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettingsWindow

    /// Settings → Cameras, with this camera's sheet open.
    func openCameraSettings() {
        model.settingsTab = .cameras
        model.cameraToEdit = camera.id
        openSettingsWindow()
    }

    /// Settings → Doctor, at this camera.
    func openDoctor() {
        model.settingsTab = .doctor
        model.doctorCamera = camera.id
        openSettingsWindow()
    }

    /// The camera as the snapshot shows it: on the stage, or about to be.
    var shownOnStage: Bool { provisional ?? onStage }

    /// How long a click waits for a second one before it changes the stage.
    static var doubleClickWait: Double { min(NSEvent.doubleClickInterval, 0.25) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Every thumbnail 16:9, whatever the camera's picture: the frame is set first and the picture fills
            // it, cropped (in the stack it would size the frame to itself, so a 4:3 doorbell came out taller).
            Color.black
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    // Private: not even its last picture.
                    if model.isPrivate(camera.id) {
                        Image(systemName: "eye.slash").font(.title3).foregroundStyle(.tertiary)
                    } else if let snapshot {
                        Image(decorative: snapshot.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            // A camera with a problem shows its last picture faded, so it stands out at a glance.
                            .opacity(health.isProblem ? 0.4 : 1)
                            .saturation(health.isProblem ? 0 : 1)
                    } else {
                        Image(systemName: "video").font(.title2).foregroundStyle(.tertiary)
                    }
                }
                .clipped()
            .overlay(alignment: .bottomLeading) {
                if health.showsBadge {
                    HealthBadge(health: health, compact: true).padding(6)
                }
            }
            // The doctor's mark, as on its tile (a problem, or a warning with a fix; not ignored): opens the doctor.
            .overlay(alignment: .bottomTrailing) {
                if let finding = model.doctor.mark(camera.id) {
                    Button(action: openDoctor) {
                        Image(systemName: "stethoscope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(finding.severity == .problem ? .red : .orange)
                            .frame(width: 22, height: 22)
                            .glassEffect(.regular, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("\(finding.headline): \(finding.evidence). Click for the doctor.")
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, lineWidth: shownOnStage ? 2.5 : 0)
                    .animation(.snappy(duration: 0.2), value: shownOnStage)
            }
            // A click dips the snapshot and springs it back.
            .keyframeAnimator(initialValue: 1.0, trigger: presses) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(0.93, duration: 0.07)
                SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
            }
            .overlay(alignment: .topTrailing) {
                // Shows what a click does; the whole snapshot is the click target.
                if hovering || shownOnStage {
                    Image(systemName: shownOnStage ? (hovering && canRemove && provisional == nil ? "minus" : "checkmark") : "plus")
                        .font(.caption.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: shownOnStage)
                        .frame(width: 22, height: 22)
                        .glassEffect(shownOnStage ? .regular.tint(.accentColor) : .regular, in: .circle)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 4) {
                Text(camera.name)
                    .font(.callout.weight(shownOnStage ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let snapshot {
                    Text(snapshot.time, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A click adds or removes the camera, a double-click shows it alone (see click()).
        .onTapGesture(perform: click)
        .contextMenu {
            Button("Watch Only This", action: solo)
            // Its controls, with it on its own.
            Button("Control This Camera", systemImage: "slider.horizontal.3", action: openControls)
            if model.isPrivateOnCameraOnly(camera.id) {
                Button("Private on the Camera", systemImage: "eye.slash") {}.disabled(true)
            } else if model.isPrivate(camera.id) {
                Button("Turn Off Privacy", systemImage: "eye") { Task { await model.setPrivacy(camera.id, false) } }
            } else {
                Button("Make Private", systemImage: "eye.slash") { Task { await model.setPrivacy(camera.id, true) } }
            }
            Button(onStage ? "Take Off the Screen" : "Add to the Screen", action: toggle)
                .disabled(onStage && !canRemove)
            Divider()
            Button("Camera Settings…", systemImage: "gearshape", action: openCameraSettings)
            Button("Doctor…", systemImage: "stethoscope", action: openDoctor)
        }
        .help(onStage ? (canRemove ? "\(camera.name): click to take off the screen" : "\(camera.name): at least one camera stays on the screen")
                      : "\(camera.name): click to add to the screen")
    }

    /// The snapshot answers a click at once; the stage waits a moment, so that the first click of a
    /// double-click never adds or removes the camera before the second one shows it alone.
    func click() {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            pending?.cancel()
            pending = nil
            provisional = nil
            solo()
            return
        }
        guard !onStage || canRemove else { return }
        presses += 1
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        provisional = !onStage
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(Self.doubleClickWait))
            guard !Task.isCancelled else { return }
            toggle()
            provisional = nil
            pending = nil
        }
    }
}

// MARK: - Stage

/// The chosen cameras, in as many columns as make the tiles largest, the last row centred.
struct Stage: View {
    let cameras: [Config.Camera]
    /// Every camera, for stand-ins of ones that have just left the stage.
    var allCameras: [Config.Camera] = []
    let snapshots: CameraSnapshots
    var activity: CameraActivity?
    var health: (String) -> CameraHealth = { _ in .ok }
    var openEvent: (TimelineEvent) -> Void = { _ in }
    var drag = ReorderDrag()
    var reorder: (String, String) -> Void = { _, _ in }
    /// A camera just added, announced with a glow.
    let justAdded: String?
    /// The change took a camera off: tiles wait for it to fade before moving into its place.
    let afterRemoval: Bool
    /// How to move for this change.
    let motion: StageMotion
    /// Cameras kept above the others while they arrive.
    var inFront: Set<String> = []

    /// Changes are coming quickly: calm motion, and tiles that change rows fade across instead of travelling.
    var fast: Bool { motion == .calm || motion == .reorder }

    /// Seconds between tiles fading in when many arrive at once (16 tiles: a quarter of a second in all).
    static let revealStagger = 0.015

    let solo: (String) -> Void
    let remove: (String) -> Void
    /// Watches a camera on its own with its controls open.
    var openControls: (String) -> Void = { _ in }

    /// The cameras as last laid out, to tell which tiles a change moves to another row.
    @State private var shownLineup: [String] = []
    /// Tiles that changed rows, hidden at their new place until they fade in.
    @State private var hiding: Set<String> = []
    /// Stills of those tiles at their old place, fading out.
    @State private var ghosts: [Ghost] = []
    /// When switching to a camera that was not on the stage: the tiles leaving, kept (live) at their places
    /// while they recede, then removed.
    @State private var departing: [Ghost] = []
    @State private var receded = false
    /// What each tile shows, so a stand-in can show the same.
    @State private var statuses: [String: TileStatus] = [:]

    /// A tile and where it goes; `leaving` while it recedes before being removed.
    struct Placed: Identifiable {
        var camera: Config.Camera
        var frame: CGRect
        var index: Int
        var leaving: Bool
        var id: String { camera.id }
    }

    struct Ghost: Identifiable, Equatable {
        var camera: String
        var frame: CGRect
        var id: String { "ghost-\(camera)" }
    }

    /// How long a tile that changes rows takes to fade across.
    static let crossfade = 0.32

    static let spacing = 10.0
    static let padding = 12.0
    /// Seconds between one tile starting to move and the next.
    static let ripple = 0.025
    /// Seconds a new tile waits for the others to make room (long enough for a tile in its slot to have
    /// mostly left it, when it lands in the middle).
    static let insertDelay = 0.3
    /// Seconds the others wait for a removed tile to fade before closing the gap.
    static let removeLead = 0.1
    /// Tiles shorter than this are compact.
    static let compactHeight = 200.0
    /// Tiles at least this wide play the main stream.
    static let mainStreamWidth = 900.0

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: geo.size.width - 2 * Self.padding, height: geo.size.height - 2 * Self.padding)
            let (columns, tile) = Self.layout(count: cameras.count, in: area)
            let centres = Self.centres(count: cameras.count, columns: columns, tile: tile, in: geo.size)
            // Changes when cameras are added or removed (not when the window is resized).
            let lineup = cameras.map(\.id)
            // In fast mode, tiles that this change moves to another row (and their old places).
            let rowChanges = fast ? Self.rowChanges(from: shownLineup, to: lineup, area: area, size: geo.size) : [:]
            // Switching to a camera not on the stage: the tiles leaving (stored once the change is seen).
            let receding = !departing.isEmpty ? departing
                : motion == .crossfade ? Self.departures(from: shownLineup, to: lineup, area: area, size: geo.size) : []
            // Each tile is placed by itself (not in rows), so when the layout changes every tile moves and
            // resizes smoothly to its new place, rather than being rebuilt in another row.
            let stageCentre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // The tiles on the stage, and any still receding (the same views, so their video keeps playing).
            let placed = receding.compactMap { ghost in
                (cameras.first { $0.id == ghost.camera } ?? departedCamera(ghost.camera))
                    .map { Placed(camera: $0, frame: ghost.frame, index: 0, leaving: true) }
            } + cameras.enumerated().map { index, camera in
                Placed(camera: camera, frame: CGRect(x: centres[index].x - tile.width / 2, y: centres[index].y - tile.height / 2,
                                                     width: tile.width, height: tile.height), index: index, leaving: false)
            }
            ZStack {
                ForEach(ghostsShown(rowChanges)) { ghost in
                    standIn(ghost).transition(.scale(scale: 0.94).combined(with: .opacity))
                }
                ForEach(placed) { place in
                    let camera = place.camera
                    let jumps = rowChanges[camera.id] != nil
                    let centre = CGPoint(x: place.frame.midX, y: place.frame.midY)
                    // Every modifier is applied whether or not the tile is leaving, so it stays the same view
                    // (and its stream keeps running) when it starts to recede.
                    let compact = place.frame.height < Self.compactHeight
                    CameraTile(camera: camera, mainStream: place.frame.width >= Self.mainStreamWidth,
                               cornerRadius: place.frame.width > 600 ? 22 : 16, snapshot: snapshots[camera.id]?.image,
                               canRemove: cameras.count > 1, announced: !place.leaving && camera.id == justAdded,
                               superseded: motion == .calm || (justAdded != nil && justAdded != camera.id),
                               solo: cameras.count > 1 ? { solo(camera.id) } : nil, remove: { remove(camera.id) },
                               openControls: { openControls(camera.id) },
                               compact: compact, health: health(camera.id), events: activity?[camera.id],
                               openEvent: openEvent)
                        .frame(width: place.frame.width, height: place.frame.height)
                        // Before .position: after it, the tile's view spans the whole stage, and every tile
                        // would take drops anywhere on it.
                        .modifier(StageReorder(id: camera.id, name: camera.name, drag: drag, enabled: !place.leaving && cameras.count > 1,
                                               move: reorder))
                        // The tile's contents follow its animated size as one, rather than each piece
                        // (icon, message, badges) animating to its new place separately.
                        .geometryGroup()
                        // Receding: every leaving tile shrinks by the same amount and moves the same fraction
                        // of the way to the stage's centre, so the grid shrinks as one, gutters and all.
                        .modifier(RecedeEffect(amount: place.leaving && receded ? 1 : 0, scale: LiveView.recedeScale,
                                               shift: CGSize(width: (LiveView.recedeScale - 1) * (centre.x - stageCentre.x),
                                                             height: (LiveView.recedeScale - 1) * (centre.y - stageCentre.y))))
                        .position(centre)
                        .scaleEffect(jumps || hiding.contains(camera.id) ? 0.94 : 1)
                        .opacity(jumps || hiding.contains(camera.id) || (place.leaving && receded) ? 0 : 1)
                        // A tile changing rows in fast mode goes straight to its new place (and fades in there).
                        // Otherwise each tile starts a little after the one before, so the grid ripples into
                        // place; quick runs of changes move calmly, all at once.
                        .animation(jumps || place.leaving ? nil : moveAnimation(place.index), value: lineup)
                        .allowsHitTesting(!place.leaving)
                        .onTapGesture(count: 2) { solo(camera.id) }
                        // Adding mirrors removing: the others make room first, then the new tile pops into the
                        // gap (rather than landing on tiles that are still moving out of the way).
                        // Placed with .position, a tile's view spans the stage: its own centre, as a point of
                        // that, anchors a single tile's scale.
                        .transition(place.leaving ? .identity
                                    : transition(tileCentre: UnitPoint(x: centre.x / max(geo.size.width, 1),
                                                                       y: centre.y / max(geo.size.height, 1)),
                                                 index: place.index))
                        .zIndex(place.leaving ? -1 : motion == .focus(camera.id) || inFront.contains(camera.id) ? 2
                                : camera.id == justAdded ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { shownLineup = lineup }
            // Kept, not replaced: a stand-in shows what its tile showed after the tile has gone.
            .onPreferenceChange(TileStatuses.self) { statuses.merge($0) { $1 } }
            .onChange(of: lineup) { old, new in
                if motion == .crossfade {
                    departing = Self.departures(from: old, to: new, area: area, size: geo.size)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(16))
                        withAnimation(LiveView.recedeAnimation) { receded = true }
                        try? await Task.sleep(for: .seconds(0.35))
                        departing = []
                        receded = false
                    }
                }
                let moved = fast ? Self.rowChanges(from: old, to: new, area: area, size: geo.size) : [:]
                shownLineup = new
                guard !moved.isEmpty else { return }
                hiding = Set(moved.keys)
                ghosts = moved.map { Ghost(camera: $0.key, frame: $0.value) }
                Task { @MainActor in
                    withAnimation(.smooth(duration: Self.crossfade)) {
                        hiding = []
                        ghosts = []
                    }
                }
            }
        }
    }

    func departedCamera(_ id: String) -> Config.Camera? {
        allCameras.first { $0.id == id }
    }

    func moveAnimation(_ index: Int) -> Animation? {
        switch motion {
        case .lively: LiveView.layoutAnimation.delay((afterRemoval ? Self.removeLead : 0) + Double(index) * Self.ripple)
        case .calm: LiveView.calmAnimation
        case .reorder: .snappy(duration: 0.3)
        case .reveal: LiveView.revealAnimation
        case .swap: nil
        case .focus: LiveView.focusAnimation
        case .crossfade: LiveView.recedeAnimation
        }
    }

    /// How tiles come and go for this change; `tileCentre` is the tile's centre as a point of the stage.
    func transition(tileCentre: UnitPoint, index: Int = 0) -> AnyTransition {
        switch motion {
        case .reveal:
            .asymmetric(insertion: .scale(scale: 0.92, anchor: tileCentre).combined(with: .opacity)
                            .animation(.smooth(duration: 0.35).delay(0.08 + Double(index) * Self.revealStagger)),
                        removal: .opacity.animation(.easeOut(duration: 0.16)))
        case .lively:
            // Adding mirrors removing: the others make room first, then the new tile pops into the gap
            // (rather than landing on tiles that are still moving out of the way).
            .asymmetric(insertion: .scale(scale: 0.6, anchor: tileCentre).combined(with: .opacity)
                            .animation(.spring(duration: 0.45, bounce: 0.35).delay(Self.insertDelay)),
                        removal: .scale(scale: 0.9, anchor: tileCentre).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.16)))
        case .calm, .reorder:
            .asymmetric(insertion: .scale(scale: 0.9, anchor: tileCentre).combined(with: .opacity)
                            .animation(.spring(duration: 0.25, bounce: 0).delay(0.12)),
                        removal: .scale(scale: 0.9, anchor: tileCentre).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.16)))
        case .swap:
            .identity
        case .focus:
            .opacity.animation(.easeInOut(duration: 0.25))
        case .crossfade:
            // The departing tiles are replaced at once by stand-ins in the receding layer (see `receding`);
            // the new camera grows by the same amount as it arrives, once the old stage has nearly gone.
            .asymmetric(insertion: .scale(scale: LiveView.recedeScale, anchor: .center).combined(with: .opacity)
                            .animation(.smooth(duration: 0.4).delay(LiveView.arriveDelay)),
                        removal: .identity)
        }
    }

    /// The ghosts fading out, and (for the moment of the change itself, before they are stored) the ones
    /// this change makes.
    func ghostsShown(_ rowChanges: [String: CGRect]) -> [Ghost] {
        var all = ghosts
        for (camera, frame) in rowChanges where !all.contains(where: { $0.camera == camera }) {
            all.append(Ghost(camera: camera, frame: frame))
        }
        return all
    }

    /// A still of a tile at a place it is leaving, showing what the tile showed.
    func standIn(_ ghost: Ghost) -> some View {
        Group {
            if let camera = cameras.first(where: { $0.id == ghost.camera }) ?? departedCamera(ghost.camera) {
                CameraTile(camera: camera, mainStream: false, cornerRadius: ghost.frame.width > 600 ? 22 : 16,
                           snapshot: snapshots[ghost.camera]?.image, frozen: statuses[ghost.camera] ?? .connecting,
                           compact: ghost.frame.height < Self.compactHeight)
            }
        }
        .frame(width: ghost.frame.width, height: ghost.frame.height)
        .position(x: ghost.frame.midX, y: ghost.frame.midY)
        .allowsHitTesting(false)
    }

    /// Cameras a change takes off the stage, with where they were.
    static func departures(from old: [String], to new: [String], area: CGSize, size: CGSize) -> [Ghost] {
        guard !old.isEmpty else { return [] }
        let (columns, tile) = layout(count: old.count, in: area)
        let oldCentres = centres(count: old.count, columns: columns, tile: tile, in: size)
        return old.enumerated().filter { !new.contains($0.element) }.map { i, id in
            let c = oldCentres[i]
            return Ghost(camera: id, frame: CGRect(x: c.x - tile.width / 2, y: c.y - tile.height / 2,
                                                   width: tile.width, height: tile.height))
        }
    }

    /// Cameras that a change from `old` to `new` moves to another row, with where they were.
    static func rowChanges(from old: [String], to new: [String], area: CGSize, size: CGSize) -> [String: CGRect] {
        guard !old.isEmpty, old != new else { return [:] }
        let (oldColumns, oldTile) = layout(count: old.count, in: area)
        let oldCentres = centres(count: old.count, columns: oldColumns, tile: oldTile, in: size)
        let (newColumns, _) = layout(count: new.count, in: area)
        var out: [String: CGRect] = [:]
        for (n, id) in new.enumerated() {
            guard let o = old.firstIndex(of: id), o / oldColumns != n / newColumns else { continue }
            let c = oldCentres[o]
            out[id] = CGRect(x: c.x - oldTile.width / 2, y: c.y - oldTile.height / 2, width: oldTile.width, height: oldTile.height)
        }
        return out
    }

    /// Where each tile's centre goes: rows from the top, the block centred, a part-filled last row centred.
    static func centres(count: Int, columns: Int, tile: CGSize, in size: CGSize) -> [CGPoint] {
        guard count > 0, columns > 0 else { return [] }
        let rows = (count + columns - 1) / columns
        let blockHeight = Double(rows) * tile.height + Double(rows - 1) * spacing
        let top = (size.height - blockHeight) / 2
        return (0 ..< count).map { i in
            let row = i / columns
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = Double(inRow) * tile.width + Double(inRow - 1) * spacing
            let left = (size.width - rowWidth) / 2
            let column = i % columns
            return CGPoint(x: left + Double(column) * (tile.width + spacing) + tile.width / 2,
                           y: top + Double(row) * (tile.height + spacing) + tile.height / 2)
        }
    }

    /// Columns and tile size that make `count` 16:9 tiles largest within `area`.
    static func layout(count: Int, in area: CGSize) -> (columns: Int, tile: CGSize) {
        guard count > 0, area.width > 0, area.height > 0 else { return (1, .zero) }
        var best = (columns: 1, tile: CGSize.zero)
        for columns in 1 ... count {
            let rows = (count + columns - 1) / columns
            let byWidth = (area.width - spacing * Double(columns - 1)) / Double(columns)
            let byHeight = (area.height - spacing * Double(rows - 1)) / Double(rows) * 16 / 9
            let width = min(byWidth, byHeight)
            if width > best.tile.width { best = (columns, CGSize(width: width, height: width * 9 / 16)) }
        }
        return best
    }
}

/// A stage tile as something to drag into a new order. One structure whether enabled or not: an if/else here
/// made the tile a different view whenever it flipped (a tile leaving, the count going to or from one), and
/// the old one then faded out over the new one.
struct StageReorder: ViewModifier {
    let id: String
    let name: String
    let drag: ReorderDrag
    let enabled: Bool
    let move: (String, String) -> Void

    func body(content: Content) -> some View {
        content.reorderable(id, name: name, drag: drag, from: .stage, enabled: enabled, move: move)
    }
}

/// Shrinks a view about its own centre and moves it by a fraction (`amount`) of `shift`: with the same
/// amount and each tile's share of the shift toward the stage's centre, a set of tiles shrinks as one.
struct RecedeEffect: GeometryEffect {
    var amount: Double
    let scale: Double
    let shift: CGSize

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let s = 1 + (scale - 1) * amount
        return ProjectionTransform(
            CGAffineTransform(translationX: size.width / 2 + shift.width * amount, y: size.height / 2 + shift.height * amount)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -size.width / 2, y: -size.height / 2))
    }
}

/// What a tile is showing.
enum TileStatus: Hashable {
    case noPassword, connecting, playing, noPicture
    /// Live view comes through the service: it isn't running, or hasn't taken this camera on.
    case serviceStopped, serviceBehind
    case failed(String)
    /// Made private in Pond: not shown (nor recorded).
    case keptPrivate
    /// Made public after its own privacy mode: starting its video again (it may fail to connect meanwhile).
    case waking
}

/// Each tile's status, collected by the stage.
struct TileStatuses: PreferenceKey {
    static let defaultValue: [String: TileStatus] = [:]
    static func reduce(value: inout [String: TileStatus], nextValue: () -> [String: TileStatus]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One camera's live picture, with its name and a recording badge; when there is no picture, its last
/// snapshot dimmed behind what is wrong.
struct CameraTile: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let mainStream: Bool
    let cornerRadius: Double
    var snapshot: CGImage?
    var canRemove = false
    /// Just added to the stage: glow, and say so.
    var announced = false
    /// Another camera has just been announced: this one's glow goes at once.
    var superseded = false
    var solo: (() -> Void)?
    var remove: (() -> Void)?
    /// Watches it on its own with its controls open.
    var openControls: (() -> Void)?
    /// A still stand-in: no connection, the snapshot, and this status.
    var frozen: TileStatus?
    /// A small tile: shorter messages and badges.
    var compact = false
    var health = CameraHealth.ok
    /// Today's events, shown on hover.
    var events: CameraActivity.Summary?
    var openEvent: (TimelineEvent) -> Void = { _ in }
    @State private var stream: LiveStream?
    /// The stream taking over (the tile grew or shrank past the size for the main stream): connecting under
    /// the current one until it plays and the tile has stopped moving; then the current one goes and stops, so
    /// the picture never goes black between them. Each stream keeps its own view all along (moved to a new view, a stream was
    /// drawn for a frame at the tile's final size while the tile was still animating to it).
    @State private var incoming: LiveStream?
    @State private var noPassword = false
    @State private var pointerInside = false
    /// The events popover is open: it has the pointer or the keyboard, so the tile's controls stay.
    @State private var popoverOpen = false

    @Namespace private var glass
    /// How close the name and gear glass must be to merge.
    static let glassMerge = 9.0
    /// Between the badges along the bottom of a tile (name, gear, REC, HomeKit, sound, resolution).
    static let badgeGap = 6.0
    /// How close glass must be to merge once the gear has moved off: less than the gap, so it stays apart.
    static let restingMerge = 3.0
    /// The height of the tile's glass controls along the bottom: the name pill and gear, the sound button
    /// and the resolution pill all line up.
    static let pillHeight = 32.0
    static let compactPillHeight = 26.0
    /// The gear is on the tile, and moved off from the name.
    @State private var gearShown = false
    @State private var gearApart = false
    @State private var gearSteps: Task<Void, Never>?
    static let gearSpring = Animation.spring(duration: 0.45, bounce: 0.15)

    /// Out: add (budding from the name), then move apart. Back: move together, then remove (melting in).
    func showGear(_ show: Bool) {
        gearSteps?.cancel()
        gearSteps = Task {
            // One spring for both steps, the second starting while the first is still moving, so they
            // read as a single motion rather than one easing handing over to another.
            if show {
                withAnimation(Self.gearSpring) { gearShown = true }
                try? await Task.sleep(for: .seconds(0.12))
                guard !Task.isCancelled else { return }
                withAnimation(Self.gearSpring) { gearApart = true }
            } else {
                withAnimation(Self.gearSpring) { gearApart = false }
                try? await Task.sleep(for: .seconds(0.12))
                guard !Task.isCancelled else { return }
                withAnimation(Self.gearSpring) { gearShown = false }
            }
        }
    }
    @Environment(\.openSettings) private var openSettingsWindow

    /// Settings → Cameras, with this camera's sheet open.
    func openSettings() {
        model.settingsTab = .cameras
        model.cameraToEdit = camera.id
        openSettingsWindow()
    }

    /// Longer than the stage's moves (its tiles growing and shrinking), so a new stream's picture shows once its
    /// tile has stopped moving.
    static let settle: TimeInterval = 0.65

    /// This camera is the one heard.
    var audible: Bool { model.audibleCamera == camera.id }
    /// Its speaker has the microphone.
    var talking: Bool { model.talking?.camera == camera.id }
    /// It has controls for the dock under the stage.
    var hasDockControls: Bool { true }

    /// Show the hover controls: the pointer is on the tile, or in its popover.
    var hovering: Bool { pointerInside || popoverOpen }

    var status: TileStatus {
        if let frozen { return frozen }
        if model.isPrivate(camera.id) { return .keptPrivate }
        if noPassword { return .noPassword }
        if model.isWaking(camera.id), stream?.state != .playing { return .waking }
        switch stream?.state {
        case .playing?: return .playing
        case .noPicture?: return .noPicture
        case .serviceStopped?: return .serviceStopped
        case .serviceBehind?: return .serviceBehind
        case let .failed(reason)?: return .failed(reason)
        case .connecting?, nil: return .connecting
        }
    }

    var playing: Bool { status == .playing }

    var body: some View {
        // No GeometryReader here: it reports a tile's final size at once while the tile is still animating
        // to it, so the contents would slide diagonally. The stage says how big the tile is instead.
        Group {
            ZStack {
                Color.black
                // Private: not even its last picture.
                if let snapshot, !playing || frozen != nil, status != .keptPrivate {
                    // Dimmed behind a message; a stand-in for a playing tile shows it plainly. Whole, as the video
                    // is (a squarer camera gets bars at the sides), so nothing jumps when the video takes over.
                    Image(decorative: snapshot, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .opacity(playing ? 1 : 0.35)
                }
                if frozen == nil {
                    // The stream taking over underneath, drawing all along (unseen, a view doesn't draw, and one
                    // shown later rose from black); the current one over it until the new one is ready.
                    // Made private: faded out where it is (then stopped); taken out at once, its view was drawn
                    // shrinking into a corner as the change animated.
                    let hidden = model.isPrivate(camera.id)
                    ForEach([incoming, stream].compactMap { $0 }) { s in
                        VideoLayerView(layer: s.layer, videoSize: s.size)
                            .opacity(s.state == .playing && !hidden ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Always: the bottom-left corner darkened softly, under the name and badges there, so they read on any
            // picture.
            .overlay {
                RadialGradient(colors: [.black.opacity(0.38), .black.opacity(0.12), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: compact ? 170 : 280)
                    .allowsHitTesting(false)
            }
            // Hovered: the top and bottom edges darkened a little, so the controls there stand out from the video.
            // Under them, and always laid out (faded), so it moves with the tile.
            .overlay {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: compact ? 44 : 72)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                        .frame(height: compact ? 52 : 84)
                }
                .opacity(hovering && frozen == nil ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .allowsHitTesting(false)
            }
            // An overlay, centred on the tile itself: inside the stack it would be centred on the snapshot,
            // which is sized for the tile's final size at once and so pulls the message off centre while
            // the tile grows.
            // One layout at every size, scaled down on small tiles (and clear of the name badge there): a
            // scale animates with the tile as one piece, where changing fonts and spacing would make the
            // icon, title and detail each drift to their new places.
            .overlay {
                // Always there, centred on the tile; a new message (made private, say) fades in where it
                // belongs, not laid out from a corner as the change animates.
                ZStack {
                    status(compact: compact)
                        .id(status)
                        .transition(.opacity)
                }
                // The tile's size whatever it holds: grown from nothing, it drew the message drifting in.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(compact ? 0.8 : 1)
                .offset(y: compact ? -10 : 0)
            }
            .overlay(alignment: .bottomLeading) { badges(compact: compact).padding(compact ? 7 : 10) }
            // The overlays below are always laid out and only faded in and out: views added or removed
            // while a tile is moving would animate from wherever they last were, not with the tile.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    // Its controls (moving it, its positions, day and night), under it on its own.
                    // Not when it's alone on the stage: its controls are under it there.
                    if hasDockControls, frozen == nil, canRemove {
                        Button { openControls?() } label: { Image(systemName: "slider.horizontal.3") }
                            .help("Controls for \(camera.name) (\u{2325}\u{2318}L)")
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                    }
                    // Only with other cameras on the stage: alone, there is nothing to enlarge it over or
                    // take it off for.
                    Group {
                        Button { solo?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Watch only this camera")
                        Button { remove?() } label: { Image(systemName: "xmark") }
                            .help("Take off the screen")
                    }
                    .opacity(hovering && solo != nil && canRemove ? 1 : 0)
                    .allowsHitTesting(hovering && solo != nil && canRemove)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(compact ? .small : .regular)
                .padding(compact ? 6 : 10)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if health.showsBadge { HealthBadge(health: health, compact: compact) }
                    if let events, events.eventsToday > 0 {
                        EventsChip(events: events, compact: compact, open: openEvent,
                                   popoverShown: { popoverOpen = $0 })
                            .opacity(hovering ? 1 : 0)
                            .allowsHitTesting(hovering)
                            .animation(.easeOut(duration: 0.15), value: hovering)
                    }
                }
                .padding(compact ? 6 : 10)
            }
            // A picture taken: a quick flash, as a shutter.
            .overlay {
                Color.white
                    .opacity(model.flash == camera.id ? 0.55 : 0)
                    .animation(model.flash == camera.id ? .easeOut(duration: 0.05) : .easeOut(duration: 0.35), value: model.flash)
                    .allowsHitTesting(false)
            }
            .overlay {
                // Something is wrong, or it's private: the tile's edge says so too.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(health.tint.opacity(health.showsEdge ? 0.7 : 0), lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Always there, switched on and off: a glow that was inserted and removed would fade out where the
        // tile used to be while the tile moved on.
        .overlay { AddedGlow(cornerRadius: cornerRadius, active: announced, superseded: superseded) }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { pointerInside = $0 }
        .preference(key: TileStatuses.self, value: frozen == nil ? [camera.id: status] : [:])
        .onChange(of: audible) { _, heard in stream?.muted = !heard }
        .onChange(of: model.isWaking(camera.id)) { _, waking in stream?.retriesSoon = waking }
        .onDisappear { stopStreams() }
        .task(id: "\(camera.id) \(camera.main) \(camera.sub) \(camera.username) \(mainStream) \(model.isPrivate(camera.id))") {
            guard frozen == nil else { return }
            // Private: not connected at all (once the picture has faded).
            guard !model.isPrivate(camera.id) else {
                try? await Task.sleep(for: .seconds(0.4))
                return stopStreams()
            }
            await play()
        }
    }

    func badges(compact: Bool) -> some View {
        HStack(spacing: Self.badgeGap) {
            // The name and, on hover, a gear for the camera's settings, in one glass container, which blends
            // glass shapes that are close into one. Hidden, the gear is a small glass seed inside the name
            // pill's rounded end (so the glass is just the pill). Shown, the seed gives way to the gear button
            // with the same glass ID: Liquid Glass morphs one into the other (budding out of the pill's end),
            // then the gear moves off (the glass pinches apart). Leaving runs the other way, melting back into
            // the pill. See `showGear`. (Without the seed, an inserted gear grew out of the whole name pill.)
            // Merging reaches far while the gear buds and pinches off, then shrinks below the badges' gap,
            // so the gear rests as far from the name as every other badge without the glass joining them.
            GlassEffectContainer(spacing: gearApart ? Self.restingMerge : Self.glassMerge) {
                // The name pill and the gear are the same height, so the gear reads as part of it.
                let size = compact ? Self.compactPillHeight : Self.pillHeight
                let seed = size * 0.6
                HStack(spacing: gearApart ? Self.badgeGap : gearShown ? 0 : -(size + seed) / 2) {
                    Text(camera.name)
                        .font(compact ? .callout.weight(.semibold) : .headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, compact ? 10 : 13)
                        .frame(height: size)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("name", in: glass)
                    if gearShown {
                        // A glass button, so its glass and its click are one control (glass painted onto a
                        // plain button reacted to the pointer apart from the button underneath).
                        Button(action: openSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(compact ? .callout : .headline)
                                // The glass button adds 4 pt round its label: the circle is then `size` across,
                                // the name pill's height.
                                .frame(width: size - 8, height: size - 8)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)
                        .glassEffectID("gear", in: glass)
                        .help("\(camera.name) settings")
                    } else {
                        Color.clear
                            .frame(width: seed, height: seed)
                            .glassEffect(.regular, in: .circle)
                            .glassEffectID("gear", in: glass)
                            // Still ending where the name does, so what follows does not slide under the name.
                            .padding(.trailing, (size - seed) / 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .onChange(of: hovering && frozen == nil, initial: true) { _, show in showGear(show) }
            // Not while it's private: it isn't being recorded.
            if model.isRecording, !model.isPrivate(camera.id) {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                    if !compact { Text("REC").font(.callout.weight(.bold)) }
                }
                .padding(.horizontal, compact ? 9 : 12)
                // As tall as the name pill, the gear and the HomeKit badge beside it.
                .frame(minWidth: compact ? Self.compactPillHeight : nil,
                       minHeight: compact ? Self.compactPillHeight : Self.pillHeight,
                       maxHeight: compact ? Self.compactPillHeight : Self.pillHeight)
                .glassEffect(.regular, in: .capsule)
                .help("Recorded continuously")
            }
            // The doctor's mark: something wrong with it, or something to change (not notices, not ignored).
            // Opens the doctor at the camera.
            if frozen == nil, let finding = model.doctor.mark(camera.id) {
                Button {
                    model.settingsTab = .doctor
                    model.doctorCamera = camera.id
                    openSettingsWindow()
                } label: {
                    Image(systemName: "stethoscope")
                        .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                        .foregroundStyle(finding.severity == .problem ? .red : .orange)
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(minHeight: compact ? Self.compactPillHeight : Self.pillHeight,
                               maxHeight: compact ? Self.compactPillHeight : Self.pillHeight)
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("\(finding.headline): \(finding.evidence). Click for the doctor.")
                .transition(.opacity)
            }
            // HomeKit: shown only for a camera that is to be in the Home app.
            if frozen == nil, let state = model.homeKitState(for: camera) {
                HomeKitBadge(camera: camera, state: state, compact: compact,
                             height: compact ? Self.compactPillHeight : Self.pillHeight)
            }
            Spacer(minLength: 0)
            // The buttons on the right come and go with the pointer as the tile's other controls do.
            HStack(spacing: Self.badgeGap) {
            // Sound: the button is there on hover, and stays while the camera is heard, so it is clear which.
            // A circle as tall as the name pill and the resolution pill.
            if stream?.hasAudio == true, frozen == nil, hovering || audible {
                let diameter = compact ? Self.compactPillHeight : Self.pillHeight
                Button { model.audibleCamera = audible ? nil : camera.id } label: {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(compact ? .callout : .headline)
                        .contentTransition(.symbolEffect(.replace))
                        // The glass button adds 4 pt round its label.
                        .frame(width: diameter - 8, height: diameter - 8)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .help(audible ? "Mute \(camera.name)" : "Listen to \(camera.name) (mutes the others)")
                .transition(.opacity)
            }
            // Talking through its speaker: on hover, and while talking (lit, with the voice's level).
            if model.controls(for: camera)?.talk != nil, frozen == nil, hovering || talking, !model.isAsleep(camera.id) {
                TalkButton(camera: camera, compact: compact)
                    .transition(.opacity)
            }
            if hovering, !compact, let size = stream?.size {
                Text("\(Int(size.width))×\(Int(size.height))")
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(height: Self.pillHeight)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    @ViewBuilder
    func status(compact: Bool) -> some View {
        switch status {
        case .noPassword:
            TileMessage(symbol: "key.slash", title: "No password", detail: "Set it in Settings → Cameras.", compact: compact)
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if !compact { Text("Connecting…").font(.callout).foregroundStyle(.secondary) }
            }
            .environment(\.colorScheme, .dark)
        case .playing:
            EmptyView()
        case .waking:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if !compact {
                    Text("Waking up\u{2026}").font(.callout).foregroundStyle(.secondary)
                    Text("Its privacy mode is off; the camera is starting its video again.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .environment(\.colorScheme, .dark)
        case .keptPrivate:
            if model.isPrivateOnCameraOnly(camera.id) {
                // Its own privacy mode: Pond can't turn it off.
                TileMessage(symbol: "eye.slash", title: "Private on the camera",
                            detail: "Its own privacy mode is on. Turn it off in \(camera.device?.appName ?? "the camera\u{2019}s own app") to watch and record it again.",
                            compact: compact)
            } else {
                TileMessage(symbol: "eye.slash", title: "Private",
                            detail: "Not recorded, shown or in the Home app until you turn privacy off.", compact: compact,
                            action: ("Turn Off Privacy", { Task { await model.setPrivacy(camera.id, false) } }))
            }
        case .noPicture:
            TileMessage(symbol: "eye.slash", title: "No picture",
                        detail: "The camera is connected but sends no video. Is privacy mode on?", compact: compact)
        case .serviceStopped, .serviceBehind:
            if let starting = model.serviceStartingWords {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if !compact { Text(starting).font(.callout).foregroundStyle(.secondary) }
                }
                .environment(\.colorScheme, .dark)
            } else if status == .serviceStopped {
                TileMessage(symbol: "pause.circle", title: "Service not running", detail: ServiceNote.stopped, compact: compact,
                            action: ("Start Service", { model.startService() }))
            } else {
                TileMessage(symbol: "arrow.clockwise.circle", title: "Not live yet", detail: ServiceNote.behind(camera.name),
                            compact: compact, action: ("Restart Service", { model.startService() }))
            }
        case let .failed(reason):
            TileMessage(symbol: "wifi.exclamationmark", title: "Can\u{2019}t connect", detail: reason, compact: compact)
        }
    }

    /// Runs the stream while the tile is on screen.
    func play() async {
        // Whether there is one, not what it is: the service uses it.
        guard model.hasPassword(camera.id) else {
            noPassword = true
            return
        }
        noPassword = false
        let s = LiveStream(url: mainStream ? camera.main : camera.sub, relay: model.streamRelay)
        s.retriesSoon = model.isWaking(camera.id)
        s.muted = !audible
        // This camera's other stream (main or sub), already playing, stays the picture until this one plays. Only
        // this camera's: a tile can be given another camera, whose picture must not stand in for this one.
        let previous = stream.flatMap { old in
            old.state == .playing && [camera.main, camera.sub].contains(old.url) ? old : nil
        }
        incoming?.stop()
        incoming = nil
        if let previous {
            s.muted = true
            incoming = s
            s.start()
            // Up to a few seconds for its first picture, and not before the tile has finished growing or shrinking
            // (its view, new, isn't animated: it has the tile's final size from the start, so shown sooner it
            // would sit cropped and out of register over the old one, which grows with the tile); then it fades
            // in over the old one, which then stops.
            let started = Date()
            for _ in 0 ..< 100 where (s.state != .playing || Date().timeIntervalSince(started) < Self.settle) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // A cut, not a fade: the same scene either way, and fading one video over another here dimmed the
            // picture by a quarter halfway through.
            if incoming === s {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    s.muted = !audible
                    stream = s
                    incoming = nil
                }
                model.liveFeeds[camera.id] = s
                previous.stop()
            }
        } else {
            stream?.stop()
            stream = s
            s.start()
            model.liveFeeds[camera.id] = s
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        // Not stopped here: a newer stream takes over from this one (and stops it once it plays), or the tile
        // has gone (onDisappear stops it), whichever runs first.
    }

    /// The tile has left the screen: its streams stop.
    func stopStreams() {
        if let stream, model.liveFeeds[camera.id] === stream { model.liveFeeds[camera.id] = nil }
        stream?.stop()
        incoming?.stop()
        stream = nil
        incoming = nil
    }
}

/// Around a tile just added to the stage: an accent ring that glows up and settles, and an "Added" label.
/// Part of every tile, shown while `active`, so it moves with its tile. It lights up once the tiles have
/// nearly settled, so it appears where the camera landed; when another camera is added it goes at once, so
/// only one is ever lit.
struct AddedGlow: View {
    let cornerRadius: Double
    let active: Bool
    let superseded: Bool

    var change: Animation {
        if active { return .spring(duration: 0.5, bounce: 0.35).delay(0.6) }
        return superseded ? .easeOut(duration: 0.15) : .easeOut(duration: 0.6)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The animations are scoped to the glow's own opacity, shadow and scale: its position and size are
        // the tile's, and must move exactly with it.
        ZStack(alignment: .top) {
            shape
                .strokeBorder(.tint, lineWidth: 3)
                .animation(change) { ring in
                    ring.shadow(color: .accentColor.opacity(0.9), radius: active ? 14 : 0)
                        .shadow(color: .accentColor.opacity(0.5), radius: active ? 28 : 0)
                        .opacity(active ? 1 : 0)
                }
            Label("Added", systemImage: "plus.circle.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.accentColor.opacity(0.5)), in: .capsule)
                .animation(change) { chip in
                    chip.scaleEffect(active ? 1 : 0.7).opacity(active ? 1 : 0)
                }
                .padding(.top, 10)
        }
        .allowsHitTesting(false)
    }
}

extension CameraHealth {
    var tint: Color {
        switch self {
        case .ok: .clear
        case .offline: .red
        case .noPicture, .notRecording: .orange
        case .startingToRecord: .gray
        // Private: a quiet dark blue-purple, apart from the problems' warm colours.
        case .keptPrivate: .indigo
        }
    }

    /// The tile's edge in its colour: for a problem, and for privacy.
    var showsEdge: Bool { isProblem || self == .keptPrivate }
}

/// A camera's problem, as a small glass badge in the problem's colour.
struct HealthBadge: View {
    let health: CameraHealth
    var compact = false

    var body: some View {
        Label {
            Text(health.title)
        } icon: {
            Image(systemName: health.symbol).foregroundStyle(health.tint)
        }
        .font((compact ? Font.caption : .callout).weight(.semibold))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .glassEffect(.regular.tint(health.tint.opacity(0.25)), in: .capsule)
        .environment(\.colorScheme, .dark)
        .help(health.detail)
    }
}

/// Today's events on a camera, and a button to watch the latest on the timeline.
struct EventsChip: View {
    let events: CameraActivity.Summary
    var compact = false
    let open: (TimelineEvent) -> Void
    /// Told when the popover opens or closes, so the tile keeps its controls showing meanwhile.
    var popoverShown: (Bool) -> Void = { _ in }
    @State private var overChip = false
    @State private var overCard = false
    @State private var showingRecent = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        chip
            .onHover { overChip = $0; updateRecent() }
            // Hovering the chip for a moment shows the latest events; it stays while the pointer is over
            // the chip or the card.
            .popover(isPresented: $showingRecent, arrowEdge: .bottom) {
                RecentEvents(events: events.recent, open: { event in
                    showingRecent = false
                    open(event)
                })
                .onHover { overCard = $0; updateRecent() }
            }
            .onChange(of: showingRecent) { _, shown in popoverShown(shown) }
    }

    func updateRecent() {
        hoverTask?.cancel()
        let wanted = overChip || overCard
        guard wanted != showingRecent else { return }
        hoverTask = Task {
            // Opening waits for a deliberate hover; closing allows the pointer to cross into the card.
            try? await Task.sleep(for: .seconds(wanted ? 0.45 : 0.3))
            guard !Task.isCancelled else { return }
            showingRecent = overChip || overCard
        }
    }

    var chip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: events.latest?.kind.symbol ?? "bell")
                    .foregroundStyle(events.latest?.kind.color ?? .secondary)
                Text("\(events.eventsToday)").monospacedDigit().fontWeight(.semibold)
                if !compact {
                    Text(events.eventsToday == 1 ? "event today" : "events today").foregroundStyle(.secondary)
                    if let latest = events.latest {
                        Text("· \(latest.start, format: .relative(presentation: .numeric, unitsStyle: .narrow))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, compact ? 8 : 10)
            if let latest = events.latest {
                Button { open(latest) } label: {
                    if compact { Image(systemName: "play.fill") } else { Label("Latest", systemImage: "play.fill") }
                }
                .buttonStyle(.glass)
                // A capsule inside the pill, with the same margin all round, so their curves run together.
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Watch the latest event on the timeline: \(latest.summary)")
            }
        }
        .font(compact ? .caption : .callout)
        .padding(.vertical, 3)
        .padding(.trailing, 3)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

/// The latest events on a camera, newest first; click one to watch it on the timeline.
struct RecentEvents: View {
    let events: [TimelineEvent]
    let open: (TimelineEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Latest events").font(.headline).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(events) { event in
                Button { open(event) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: event.kind.symbol).foregroundStyle(event.kind.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.kind.title).fontWeight(.semibold)
                                Spacer(minLength: 12)
                                Text(event.start, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Watch on the timeline")
            }
        }
        .padding(10)
        .frame(width: 300)
    }
}

/// What is wrong with a tile; small tiles get the title alone.
struct TileMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var compact = false
    /// What to do about it, as a button under the detail (not on small tiles).
    var action: (label: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                // The detail hangs from the title, so the icon and title stay put whether it shows or not;
                // on small tiles it fades out.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(width: Self.detailWidth)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action {
                            Button(action.label, action: action.perform)
                                .buttonStyle(.glass)
                                .controlSize(.regular)
                                // Its own width, not the title's (which the detail hangs from).
                                .fixedSize()
                        }
                    }
                    .alignmentGuide(.bottom) { $0[.top] - 6 }
                    .opacity(compact ? 0 : 1)
                    .allowsHitTesting(!compact)
                }
        }
        .environment(\.colorScheme, .dark)
    }

    static let detailWidth = 260.0
}

/// Shows an AVSampleBufferDisplayLayer, kept the size of the view.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// The picture's size, when known: a picture nearly the tile's shape fills it (see HostView).
    var videoSize: CGSize?

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.video = layer
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.video = layer
        view.videoSize = videoSize
    }

    final class HostView: NSView {
        var video: AVSampleBufferDisplayLayer? {
            didSet {
                guard video !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let video {
                    // Sized with the view in the same step (resizing it later, in layout, left a frame where a
                    // tile that had just changed size showed its video at the old size, in a corner).
                    video.frame = layer?.bounds ?? bounds
                    video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                    layer?.addSublayer(video)
                }
                needsLayout = true
            }
        }

        var videoSize: CGSize? {
            didSet { if videoSize != oldValue { needsLayout = true } }
        }

        /// How far a picture's shape may be from the tile's and still fill it (a sliver cropped, rather than
        /// thin black bars, as for a sub-stream a little narrower than 16:9); further, it fits whole.
        static let fillTolerance = 0.06

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            video?.frame = bounds
            if let videoSize, videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 {
                let picture = videoSize.width / videoSize.height, tile = bounds.width / bounds.height
                video?.videoGravity = abs(picture / tile - 1) <= Self.fillTolerance ? .resizeAspectFill : .resizeAspect
            }
            CATransaction.commit()
        }
    }
}

/// What a live view says when the service it comes through isn't there for it.
enum ServiceNote {
    static let stopped = "Live view comes through Pond\u{2019}s background service, which also records."
    static func behind(_ name: String) -> String {
        "Pond\u{2019}s background service started before \(name) was set up as it is now."
    }
}
