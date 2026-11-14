// Live: a rail of every camera (snapshots, in priority order) beside a stage showing the chosen ones live.
// Click a camera in the rail to add it to the stage or take it off; double-click it to watch it alone. The
// stage lays its tiles out as large as the window allows. Large tiles play the main stream, small ones the
// sub-stream.
import AVFoundation
import PondCore
import SwiftUI

/// How the stage moves for a change.
enum StageMotion: Equatable {
    /// One change on its own: springy, rippling, new tiles popping in.
    case lively
    /// Changes in quick succession: calm, no ripple, less bounce.
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
    @AppStorage("liveCameras", store: AppDefaults.store) private var stagedIDs = ""
    /// The same, for this session: what the stage shows. Kept in view state, because a change to stored
    /// preferences can arrive as a separate update, after the animation meant for it.
    @State private var stagedList: [String]?
    @AppStorage(LiveView.railKey, store: AppDefaults.store) private var showRail = true
    /// The rail as drawn: the stored preference, followed (it changes apart from the animation meant for it), or
    /// set here with the stage, so the rail coming back or stepping aside as one camera becomes several (or one)
    /// moves in the same animation as the tiles and the sidebar, not on its own a moment later.
    /// (Started from the preference, not left to fall back on it: falling back, a change of it was drawn at
    /// once, with nothing left for the animated following below to do.)
    @State private var railShown = AppDefaults.store.object(forKey: LiveView.railKey) as? Bool ?? true
    /// The dock's adjustments shown (its stored preference), to bring their sidebar with the stage's change.
    @AppStorage(LiveControlsDock.adjustingKey, store: AppDefaults.store) private var dockAdjusting = false
    private var railDrawn: Bool { railShown }
    /// The live controls dock is open under a camera watched on its own: kept between launches, and in view
    /// state for this session (a stored preference's change can arrive apart from the animation meant for it,
    /// and the dock and stage would then jump).
    @AppStorage("liveControls", store: AppDefaults.store) private var controlsKept = false
    @State private var controlsShown: Bool?
    private var controlsWanted: Bool { controlsShown ?? controlsKept }
    /// The dock is shown once what's in it is known (a camera's positions, its night mode): opening before, it
    /// shifted as they arrived. Known once a session; switching cameras after, the dock stays open.
    @State private var dockReady = false
    /// The rail has just stepped aside for the controls: a note says so for a moment.
    @State private var railNote = false
    /// The live view's width (the rail, the stage and the adjustments' column).
    @State private var contentWidth: CGFloat = 0
    @AppStorage(LiveView.railWidthKey, store: AppDefaults.store) private var railKeptWidth = CameraRail.defaultWidth
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
    /// Changes asked for (a click, a key, the toolbar): the first ends the shell's stillness as the view opens, so what
    /// one does animates at once; what arrives by itself as it opens doesn't (`LiveShellView.quiet`).
    @State private var acted = 0

    static let railKey = "liveRail"
    /// The rail's width, as kept (dragged by its handle, `LiveShellView`).
    static let railWidthKey = "liveRailWidth"
    static let defaultCount = 4

    var body: some View {
        let cameras = model.liveCameras
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
                shellView(cameras)
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
                    acted += 1
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
                // The overview's Show These Cameras: those that need attention, alone on the stage (the rail filtered
                // to them too).
                // The camera window's Show in Live: that camera alone.
                // (The snapshot mode's timing of Live, doing as the user would.)
                .onChange(of: model.liveDrive) { _, drive in
                    guard let drive else { return }
                    let ids = model.liveCameras.map(\.id)
                    switch drive.action {
                    case let .toggle(n): if ids.indices.contains(n) { toggle(ids[n]) }
                    case let .solo(n): if ids.indices.contains(n) { solo(ids[n]) }
                    case .showAll: showAll(ids)
                    case let .rail(shown): showRail = shown
                    case let .controls(open): setControls(open: open)
                    case let .adjustments(shown): dockAdjusting = shown
                    }
                }
                .onChange(of: model.soloRequest, initial: true) { _, asked in
                    guard let asked else { return }
                    if model.liveCameras.contains(where: { $0.id == asked }) { solo(asked) }
                    model.soloRequest = nil
                }
                .onChange(of: model.stagingNeedsAttention, initial: true) { _, asked in
                    guard asked > 0 else { return }
                    let needing = model.attentionCameras
                    let ids = model.liveCameras.map(\.id).filter { needing.contains($0) }
                    if !ids.isEmpty { showAll(ids) }
                    model.stagingNeedsAttention = 0
                }
                .onChange(of: staged(cameras), initial: true) { _, ids in
                    let mixes = Set(ids.map(AppModel.pond(of:))).count > 1
                    if model.stageMixesPonds != mixes { model.stageMixesPonds = mixes }
                }
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
                // This Mac's from its recordings; other Ponds' as they send them.
                let (others, own) = cameras.map(\.id).partitioned { AppModel.pond(of: $0) != nil }
                await snapshots.refresh(base: base, cameras: own)
                await snapshots.refreshRemote(others, client: model.controlClient)
                await activity.refresh(base: base, cameras: own, source: EventSource(config: model.config))
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// How a camera is doing. Staleness of recordings counts while the recorder runs; in the mock (where
    /// nothing records), against the newest recording of any camera, so a camera that stopped stands out.
    func health(_ id: String, cameras: [Config.Camera]) -> CameraHealth {
        if model.isPrivate(id) { return .keptPrivate }
        // Another Pond's camera: only what its live view shows (its recordings are that Pond's).
        if AppModel.pond(of: id) != nil {
            return CameraHealth.of(live: staged(cameras).contains(id) ? liveStatus[id] : nil, lastRecorded: nil, recordingAsOf: nil,
                                   startedRecording: nil)
        }
        let asOf: Date? = model.isRecording ? Date() : nil
        return CameraHealth.of(live: staged(cameras).contains(id) ? liveStatus[id] : nil,
                               lastRecorded: snapshots[id]?.time, recordingAsOf: asOf,
                               startedRecording: [model.recordingStarted[id], model.serviceStarted].compactMap { $0 }.max())
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

    /// The rail, the stage, the dock and the sidebar in AppKit (`LiveShell`): moved by Core Animation, together.
    func shellView(_ cameras: [Config.Camera]) -> some View {
        let docked = docked(cameras)
        let onStage = cameras.filter { staged(cameras).contains($0.id) }
        let sidebar = docked.flatMap { d -> AnyView? in
            guard controlsOpen, model.adjustmentsInSidebar, !model.sidebarFloats else { return nil }
            return AnyView(AdjustmentsView(camera: d.camera, controls: d.controls)
                .frame(width: LiveLayout.sidebarWidth)
                .background(.quaternary.opacity(0.35), in: LiveLayout.panel(nearWindowCorner: .bottomTrailing))
                .padding(.trailing, LiveLayout.sidebarInset)
                .padding(.vertical, 12))
        }
        return LiveShell(
            rail: AnyView(railView(cameras).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)),
            railShown: railDrawn, railWidth: CGFloat(railKeptWidth.clamped(to: CameraRail.widths)),
            stage: LiveStageShell(cameras: onStage, allCameras: cameras, snapshots: snapshots, activity: activity,
                                  health: Dictionary(onStage.map { ($0.id, health($0.id, cameras: cameras)) }) { $1 },
                                  justAdded: justAdded, afterRemoval: lastRemoved, motion: motion, inFront: inFront,
                                  drag: reorderDrag, reorder: reorder, solo: solo, remove: { toggle($0) },
                                  openControls: { openControls($0) }, openEvent: openEvent,
                                  statuses: { if liveStatus != $0 { liveStatus = $0 } }, model: model),
            dockButton: docked.map { _ in AnyView(controlsButton.chromeHit()) },
            dock: docked.map { d in
                AnyView(LiveControlsDock(camera: d.camera, controls: d.controls, open: controlsOpen)
                    .chromeHit(controlsOpen)
                    .padding(.horizontal, LiveLayout.dockInset))
            },
            dockOpen: controlsOpen,
            dockOver: !(controlsOpen && model.morePositionsOpen == nil),
            sidebar: sidebar, acted: acted, model: model)
    }

    /// The cameras' rail.
    func railView(_ cameras: [Config.Camera]) -> some View {
        CameraRail(cameras: railOrder.map { order in order.compactMap { id in cameras.first { $0.id == id } } } ?? cameras,
                   staged: staged(cameras), snapshots: snapshots,
                   health: { health($0, cameras: cameras) },
                   solo: solo, toggle: toggle, showAll: { showAll($0) },
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
        acted += 1
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
        let cameras = model.liveCameras
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
        acted += 1
        // Only among the cameras of one Pond: another Pond's, in the order kept here for it.
        guard AppModel.pond(of: id) == AppModel.pond(of: target) else { return }
        motion = .reorder
        withAnimation(.snappy(duration: 0.3)) {
            if AppModel.pond(of: id) == nil { model.moveCamera(id, onto: target) } else { model.moveRemoteCamera(id, onto: target) }
        }
    }

    /// Every camera on the stage, gently.
    func showAll(_ ids: [String]) {
        acted += 1
        announcement?.cancel()
        pendingAnnouncement = nil
        justAdded = nil
        lastRemoved = false
        lastChange = .distantPast
        motion = .reveal
        inFront = Set(staged(model.liveCameras))
        withAnimation(Self.revealAnimation) {
            alongStage(next: ids)
            stagedList = ids
        }
        stagedIDs = ids.joined(separator: ",")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            inFront = []
        }
    }

    /// Shows one camera alone: instantly from another single camera; from a multi-view, by growing it to
    /// fill the stage while the others fade (or a crossfade, when it was not on the stage).
    func solo(_ id: String) {
        acted += 1
        let before = staged(model.liveCameras)
        guard before != [id] else { return }
        announcement?.cancel()
        pendingAnnouncement = nil
        justAdded = nil
        lastRemoved = false
        lastChange = .distantPast
        // From one camera alone to another, as from several to one not among them: the one leaving recedes and fades
        // (and goes out of focus), the other arriving.
        let next: StageMotion = before.contains(id) ? .focus(id) : .crossfade
        // (The stage reads the motion with the change, in the same update.)
        motion = next
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

    /// Adds a camera to the stage, or takes it off (keeping at least one).
    func toggle(_ id: String) {
        acted += 1
        let now = Date()
        motion = now.timeIntervalSince(lastChange) < Self.fastPace ? .calm : .lively
        lastChange = now
        var ids = staged(model.liveCameras)
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
            guard !Task.isCancelled, let candidate, staged(model.liveCameras).contains(candidate) else { return }
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
    /// Puts these on the stage, alone: every camera, or (filtered) those that need attention.
    let showAll: ([String]) -> Void
    /// Watches a camera on its own with its controls open.
    var openControls: (String) -> Void = { _ in }
    let drag: ReorderDrag
    let reorder: (String, String) -> Void
    /// Its width as laid out: the room the shell gives it (`LiveShellView`, which also resizes it, by its handle).
    @State private var width = CameraRail.defaultWidth
    @Environment(AppModel.self) private var model
    /// Where the cameras are, and where the header ends and the footer begins, in the rail.
    @State private var contentSpan = 0.0 ... 0.0
    @State private var headerBottom = 0.0
    @State private var footerTop = 0.0
    /// Whether cameras are under the rail's header and footer now.
    var overflow: RailOverflow {
        RailOverflow(top: contentSpan.lowerBound < headerBottom - 1, bottom: footerTop > 0 && contentSpan.upperBound > footerTop + 1)
    }
    nonisolated static let railSpace = "rail"
    /// Ponds whose cameras are folded away in the rail (their ids; "" this Mac), kept.
    @AppStorage("railFoldedPonds", store: AppDefaults.store) private var foldedText = ""
    /// The same, once changed here (the view's own state: what's kept is read again only when the rail appears).
    @State private var folded: Set<String>?

    static let defaultWidth = 220.0
    /// Between the Ponds' panels, and above the first.
    static let pondGap = 10.0
    static let widths = 180.0 ... 460.0
    /// The narrowest a snapshot gets before the rail goes back to one column.
    static let thumbnailWidth = 150.0

    /// As many columns of at least `thumbnailWidth` as fit, but no more than there are cameras: a single
    /// camera in a wide rail gets the whole width rather than half of it.
    var columns: Int {
        let inner = width - 24
        let fit = max(1, Int((inner + 10) / (Self.thumbnailWidth + 10)))
        return min(fit, max(1, cameras.count))
    }

    var body: some View {
        // The cameras the rail's whole height, scrolling on under its header and footer: bars of translucent glass,
        // blurring what passes under them.
        ScrollView {
            VStack(spacing: 0) {
                // Several Ponds shown: a section each, on a panel of its own, under its name, folding away. While a
                // camera's dragged, its Pond's panel is lit: its cameras are the ones it can go among.
                let groups = model.cameraGroups
                if groups.count > 1 {
                    VStack(alignment: .leading, spacing: Self.pondGap) {
                        ForEach(groups, id: \.name) { group in
                            let key = group.pond ?? ""
                            let ids = Set(group.cameras.map(\.id))
                            let lit = drag.camera.map { AppModel.pond(of: $0) == group.pond && drag.source != .settings } ?? false
                            VStack(alignment: .leading, spacing: 8) {
                                PondHeading(name: group.name, pond: group.pond, count: ids.count, folded: folding(key))
                                if !foldedPonds.contains(key) {
                                    grid(shown.filter { ids.contains($0.id) })
                                }
                            }
                            .padding(8)
                            .background(lit ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.45)),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(lit ? 0.6 : 0), lineWidth: 1.5)
                            }
                            .animation(.easeOut(duration: 0.15), value: lit)
                        }
                    }
                    .padding(.horizontal, 8)
                    // Clear of the header bar by as much as the Ponds' panels are of each other.
                    .padding(.top, Self.pondGap)
                    .padding(.bottom, 12)
                } else {
                    grid(shown)
                        .padding(.horizontal, 12)
                        // (A little clear of the header at rest, so nothing's under it until the cameras move.)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                }
            }
            // Where the cameras are, against the bars (told from the first: the scroll view's own geometry is only
            // told as it changes).
            .onGeometryChange(for: ClosedRange<Double>.self) { g in
                let f = g.frame(in: .named(Self.railSpace))
                return f.minY ... max(f.minY, f.maxY)
            } action: { contentSpan = $0 }
        }
        // No scroll bar, even where the Mac's set to show them always: it took width from the thumbnails as it came
        // and went, resizing them. The hairlines under the header and over the footer say there's more.
        .scrollIndicators(.never)
        .safeAreaBar(edge: .top, spacing: 0) {
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
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { hairline(overflow.top) }
            .onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.railSpace)).maxY } action: { headerBottom = $0 }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
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
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { hairline(overflow.bottom) }
            .onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.railSpace)).minY } action: { footerTop = $0 }
        }
        // (The bars blur what's under them themselves. The system's edge effect off: it draws a line along a bar
        // whether or not anything's under it; the bars draw their own, only while something is.)
        .scrollEdgeEffectHidden(true, for: [.top, .bottom])
        .coordinateSpace(.named(Self.railSpace))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .background(.quaternary.opacity(0.35), in: LiveLayout.panel(nearWindowCorner: .bottomLeading))
        // (What scrolls under the bars kept inside the rail's corners.)
        .clipShape(LiveLayout.panel(nearWindowCorner: .bottomLeading))
        .padding([.leading, .vertical], LiveLayout.railLeading)
        .padding(.trailing, LiveLayout.railTrailing)
    }
}

extension CameraRail {
    /// A bar's edge facing the cameras: ruled off from them while some are under it.
    func hairline(_ shown: Bool) -> some View {
        Rectangle().fill(.separator).frame(height: 1).opacity(shown ? 1 : 0).animation(.easeOut(duration: 0.15), value: shown)
    }

    /// The cameras that need attention: those in the overview's list (the service watch's, the doctor's), so the
    /// rail's count is the toolbar's. (A tile gone offline a moment isn't yet: it counts once it's missed recording.)
    var needingAttention: [Config.Camera] {
        let listed = model.attentionCameras
        return cameras.filter { listed.contains($0.id) }
    }

    /// Whether the rail shows only those (while there are any).
    var filtering: Bool { model.railNeedsAttention && !needingAttention.isEmpty }

    /// The cameras the rail shows: all, or those that need attention.
    var shown: [Config.Camera] {
        guard filtering else { return cameras }
        let ids = Set(needingAttention.map(\.id))
        return cameras.filter { ids.contains($0.id) }
    }

    /// Folded away: as kept (read once, when the rail first appears), then as changed here.
    var foldedPonds: Set<String> {
        folded ?? Set(foldedText.split(separator: ",").map { $0 == "-" ? "" : String($0) })
    }

    /// Folding a Pond's section (at once), and kept.
    func folding(_ key: String) -> Binding<Bool> {
        Binding(get: { foldedPonds.contains(key) }, set: { fold in
            var set = foldedPonds
            if fold { set.insert(key) } else { set.remove(key) }
            folded = set
            // ("" is this Mac: kept as "-" so it isn't lost among the commas.)
            foldedText = set.map { $0.isEmpty ? "-" : $0 }.sorted().joined(separator: ",")
        })
    }

    func grid(_ cameras: [Config.Camera]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), spacing: 10) {
            ForEach(cameras) { camera in
                RailThumbnail(camera: camera, snapshot: snapshots[camera.id], health: health(camera.id),
                              onStage: staged.contains(camera.id),
                              canRemove: staged.count > 1, solo: { solo(camera.id) }, toggle: { toggle(camera.id) },
                              openControls: { openControls(camera.id) })
                    .reorderable(camera.id, name: camera.name, drag: drag, from: .rail, move: reorder)
            }
        }
    }

    func header(count: Bool, title: Bool) -> some View {
        HStack {
            Text("Cameras").font(.headline)
            if count {
                Text("\(staged.count) of \(cameras.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // Only while some need attention: a filter to those alone.
            let count = needingAttention.count
            if count > 0 {
                AttentionFilterButton(count: count, on: filtering) {
                    // With all the rail's cameras on the stage (Show All), the stage follows the filter: those that
                    // need attention alone, or every camera again.
                    let allShown = Set(staged) == Set(shown.map(\.id))
                    let on = !filtering
                    withAnimation(.snappy(duration: 0.25)) { model.railNeedsAttention = on }
                    if allShown {
                        let needing = Set(needingAttention.map(\.id))
                        showAll(cameras.map(\.id).filter { !on || needing.contains($0) })
                    }
                }
            }
            // Filtered, Show All is all of those shown: the cameras that need attention, alone on the stage.
            let ids = shown.map(\.id)
            ShowAllButton(allShown: Set(staged) == Set(ids), title: title, filtered: filtering) { showAll(ids) }
        }
        .lineLimit(1)
    }
}

/// Whether cameras are under the rail's header and footer.
struct RailOverflow: Equatable {
    var top: Bool
    var bottom: Bool
}

/// The rail's filter: only the cameras that need attention, and how many. On, tinted orange.
struct AttentionFilterButton: View {
    let count: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.orange))
                Text("\(count)").monospacedDigit()
            }
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(on ? .orange : nil)
        .controlSize(.small)
        .focusEffectDisabled()
        .help(on ? "Show every camera in the rail" : count == 1 ? "Show only the camera that needs attention"
                                                               : "Show only the \(count) cameras that need attention")
        .accessibilityLabel(on ? "Showing cameras that need attention" : "Show only cameras that need attention")
    }
}

/// Puts every camera on the stage. While they all are, it shows so: tinted, with a checkmark that morphs in
/// from the grid symbol, and it does nothing when clicked.
struct ShowAllButton: View {
    let allShown: Bool
    /// Room for the words; otherwise the symbol alone.
    let title: Bool
    /// The rail shows only the cameras that need attention: all of those.
    var filtered = false
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
        .help(filtered ? (allShown ? "Every camera that needs attention is on the screen" : "Put every camera that needs attention on the screen")
                       : allShown ? "Every camera is on the screen" : "Put every camera on the screen")
        .accessibilityLabel(allShown ? "All cameras shown" : "Show all cameras")
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

    /// The camera's settings, on its page in the camera window.
    func openCameraSettings() { model.showCameraSettings(camera.id) }

    /// The doctor's window, at this camera.
    func openDoctor() { model.showDoctor(camera: camera.id) }

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
            Button("Edit Zones…", systemImage: "square.dashed") { model.editZones(camera.id) }
                .disabled(!model.canEditZones(camera.id))
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

/// Where the stage's tiles go (`LiveStageView`): the chosen cameras, in as many columns as make them largest, the last
/// row centred; and the timings of its moves.
enum Stage {
    /// Seconds between tiles fading in when many arrive at once (16 tiles: a quarter of a second in all).
    static let revealStagger = 0.015
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

enum TileStatus: Hashable {
    case noPassword, connecting, playing, noPicture
    /// Live view comes through the service: it isn't running, or hasn't taken this camera on.
    case serviceStopped, serviceBehind
    case failed(String)
    /// Made private in Pond: not shown (nor recorded).
    case keptPrivate
    /// Made public after its own privacy mode: starting its video again (it may fail to connect meanwhile).
    case waking

    /// The middle of the tile says what's going on (no picture, and why): the badge at the top would say it again.
    var saysItself: Bool {
        switch self {
        case .playing, .connecting: false
        default: true
        }
    }
}

/// A live tile's measures and timings (`StageTileView`), and its badges.
enum CameraTile {
    /// The stream taking over (the tile grew or shrank past the size for the main stream) fades in over this long.
    static let crossfade = 0.3
    /// Between the badges along the bottom of a tile (name, gear, privacy, HomeKit, sound, resolution).
    static let badgeGap = 6.0
    /// The height of the tile's glass controls along the bottom: the name pill and gear, the sound button
    /// and the resolution pill all line up.
    static let pillHeight = 32.0
    static let compactPillHeight = 26.0
    /// Longer than the stage's moves (its tiles growing and shrinking), so a new stream's picture shows once its
    /// tile has stopped moving.
    static let settle: TimeInterval = 0.65

    /// The badges beside a tile's name, always in this order: privacy (by the name), the gear, the doctor's mark,
    /// HomeKit.
    enum TileBadge: String, Identifiable, CaseIterable {
        case privacy, gear, doctor, homeKit
        var id: String { rawValue }
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

    /// The tile's edge in its colour: for a problem (not privacy, a choice: the tile says it in the middle).
    var showsEdge: Bool { isProblem }
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
    /// The pointer's on Latest: its highlight.
    @State private var overLatest = false

    var body: some View {
        chip
            // Hovering the count for a moment shows the latest events; it stays while the pointer is over the count
            // or the card. (Not over Latest: a click with the card open went to closing it, so Latest took two.)
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
            .contentShape(Rectangle())
            .onHover { overChip = $0; updateRecent() }
            if let latest = events.latest {
                // The pill split in two, not glass in glass (which read as two layers): a hairline, then Latest as
                // plain text, a soft highlight behind it on hover (a capsule inside the pill, the same margin all
                // round, so their curves run together).
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: compact ? 12 : 14)
                    // Midway: as far from the text as from Latest's symbol (whose button keeps room inside for its
                    // highlight).
                    .padding(.leading, compact ? 7 : 10)
                    // Midway between the words and Latest's mark: as far from the words as Latest's own padding (for
                    // its highlight) holds its mark from it.
                    .padding(.leading, compact ? 7 : 10)
                Button { open(latest) } label: {
                    Group {
                        if compact { Image(systemName: "play.fill") } else { Label("Latest", systemImage: "play.fill") }
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 3 : 4)
                    .background(Capsule().fill(.white.opacity(overLatest ? 0.14 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Watch the latest event on the timeline: \(latest.summary)")
                // On it, the card goes at once, so the click is Latest's.
                .onHover { over in
                    withAnimation(.easeOut(duration: 0.12)) { overLatest = over }
                    guard over else { return }
                    hoverTask?.cancel()
                    overChip = false
                    overCard = false
                    showingRecent = false
                }
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

/// Beside a tile's name: makes the camera private, or (lit) public again. One button whatever its state, only its
/// tint changing: private, the indigo-tinted glass of the "Private" badge. (The glass button style takes its tint
/// from `.tint`; a tint given in its glass, `.glass(.regular.tint(…))`, it ignores.)
struct PrivacyButton: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let diameter: CGFloat
    var compact = false

    var body: some View {
        let isPrivate = model.isPrivate(camera.id)
        Button { Task { await model.setPrivacy(camera.id, !isPrivate) } } label: {
            Image(systemName: isPrivate ? "eye.slash.fill" : "eye.slash")
                .font(compact ? .callout : .headline)
                .foregroundStyle(isPrivate ? AnyShapeStyle(CameraHealth.keptPrivate.tint) : AnyShapeStyle(.primary))
                // The glass button adds 4 pt round its label: a circle as tall as the name pill.
                .frame(width: diameter - 8, height: diameter - 8)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .tint(isPrivate ? CameraHealth.keptPrivate.tint.opacity(0.25) : nil)
        .help(isPrivate ? "Private: not recorded, shown live or in the Home app. Click to record \(camera.name) again."
                        : "Make \(camera.name) private: not recorded, shown live or in the Home app until you turn it off")
    }
}

/// What a tile without its picture says, in the middle, by how much it matters:
/// - calm (chosen, or on its way: private, connecting, waking): a mark and a word or two, quiet;
/// - a problem: what's wrong, why, and a button where there's something to do (`TileMessage`).
/// Said once: the badge at the top is for a tile that's playing (`TileStatus.saysItself`); privacy's one switch is
/// the eye beside the name.
struct TileStatusWords: View {
    @Environment(AppModel.self) private var model
    let status: TileStatus
    let camera: Config.Camera
    var compact = false

    var body: some View {
        switch status {
        case .playing:
            EmptyView()
        case .connecting:
            TileNote(title: "Connecting\u{2026}", spinning: true, compact: compact)
        case .waking:
            TileNote(title: "Waking up\u{2026}", spinning: true, compact: compact)
        case .keptPrivate:
            if model.isPrivateOnCameraOnly(camera.id) {
                // Its own privacy mode: Pond can't turn it off; where to, in a line.
                TileNote(symbol: "eye.slash", title: "Private on the camera",
                         line: "Turn it off in \(camera.device?.appName ?? "the camera\u{2019}s own app")", compact: compact)
            } else {
                TileNote(symbol: "eye.slash", title: "Private", compact: compact)
            }
        case .noPassword:
            TileMessage(symbol: "key.slash", title: "No password", detail: "Pond needs it to log in to the camera.", compact: compact,
                        action: ("Open Settings", { model.editCameraSettings(camera.id) }))
        case .noPicture:
            TileMessage(symbol: "eye.slash", title: "No picture",
                        detail: "The camera is connected but sends no video. Is its own privacy mode on?", compact: compact)
        case .serviceStopped, .serviceBehind:
            if let starting = model.serviceStartingWords {
                TileNote(title: starting, spinning: true, compact: compact)
            } else if status == .serviceStopped {
                TileMessage(symbol: "pause.circle", title: "Service not running", detail: ServiceNote.stopped, compact: compact,
                            action: ("Start Service", { model.startService() }))
            } else {
                TileMessage(symbol: "arrow.clockwise.circle", title: "Not live yet", detail: ServiceNote.behind(camera.name),
                            compact: compact, action: ("Restart Service", { model.startService() }))
            }
        case let .failed(reason):
            TileMessage(symbol: "wifi.exclamationmark", title: CameraHealth.offline(reason).title, detail: reason, compact: compact)
        }
    }
}

/// A calm state, in the middle of a tile: a mark (or a spinner) and a word or two, and at most a short line; small
/// tiles, the mark (and the words, unless it's a spinner).
struct TileNote: View {
    var symbol: String?
    let title: String
    var line: String?
    var spinning = false
    var compact = false

    var body: some View {
        VStack(spacing: 8) {
            if spinning {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).font(compact ? .body : .title3).foregroundStyle(.secondary)
            }
            if !(compact && spinning) {
                Text(title).font((compact ? Font.caption : .callout).weight(.medium)).foregroundStyle(.secondary)
            }
            if !compact, let line {
                Text(line).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 240)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(line.map { "\(title). \($0)" } ?? title)
        .environment(\.colorScheme, .dark)
    }
}

/// What is wrong with a tile; small tiles get the title alone.
struct TileMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var compact = false
    /// What to do about it, as a button under the detail (smaller, or left to the tooltip, on small tiles).
    var action: (label: String, perform: () -> Void)?

    /// Room kept clear above and below: the tile's badges (its state at the top; its name and the rest at the
    /// bottom).
    static let clearTop = 44.0, clearBottom = 54.0
    static let detailWidth = 260.0

    var body: some View {
        // As much of it as fits the room between the badges: all of it; without the detail; the symbol and title with
        // a small button; the symbol alone (the rest in its tooltip).
        ViewThatFits {
            if !compact { full }
            titled(button: .regular)
            titled(button: .small)
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                .help("\(title). \(detail)")
        }
        .padding(.horizontal, 12)
        .padding(.top, Self.clearTop)
        .padding(.bottom, Self.clearBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    var full: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: Self.detailWidth)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.label, action: action.perform)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .fixedSize()
                    // (Clicked in the AppKit stage's tile, not passed through to the tile under it.)
                    .chromeHit()
                    .padding(.top, 4)
            }
        }
    }

    func titled(button size: ControlSize) -> some View {
        VStack(spacing: size == .small ? 4 : 6) {
            Image(systemName: symbol).font(size == .small ? .title3 : .title2).foregroundStyle(.secondary)
            Text(title).font(size == .small ? .callout.weight(.semibold) : .headline).lineLimit(1)
            if let action {
                Button(action.label, action: action.perform)
                    .buttonStyle(.glass)
                    .controlSize(size)
                    .fixedSize()
                    .chromeHit()
                    .padding(.top, 2)
            }
        }
        .help(detail)
    }
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

extension Array {
    /// Those that match, and those that don't, each in order.
    func partitioned(_ matches: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = [], no: [Element] = []
        for e in self { if matches(e) { yes.append(e) } else { no.append(e) } }
        return (yes, no)
    }
}
