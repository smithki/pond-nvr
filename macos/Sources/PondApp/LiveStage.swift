// Live's stage in AppKit: each tile is layers (its picture and video resized by Core Animation) with its badges and
// buttons (SwiftUI, hosted, small) carried with its corners, never laid out again while it moves; every change of
// the stage (a camera added or taken off, one watched alone, all shown) is moved by Core Animation, as the SwiftUI
// stage (`Stage`) moved it, case by case (docs/live-stage.md): nothing is worked out again frame by frame.
//
// What's on the stage, and how it moves for each change, is still decided by `LiveView`, as it was for `Stage`.
import AVFoundation
import AppKit
import Observation
import PondCore
import SwiftUI

struct LiveStageShell: NSViewRepresentable {
    /// The cameras on the stage, in order.
    let cameras: [Config.Camera]
    /// Every camera (for stand-ins of ones that have just left).
    let allCameras: [Config.Camera]
    let snapshots: CameraSnapshots
    let activity: CameraActivity
    let health: [String: CameraHealth]
    let justAdded: String?
    let afterRemoval: Bool
    let motion: StageMotion
    let inFront: Set<String>
    let drag: ReorderDrag
    let reorder: (String, String) -> Void
    let solo: (String) -> Void
    let remove: (String) -> Void
    let openControls: (String) -> Void
    let openEvent: (TimelineEvent) -> Void
    /// What each tile shows (as `TileStatuses` told it).
    let statuses: ([String: TileStatus]) -> Void
    let model: AppModel

    func makeNSView(context: Context) -> LiveStageView { LiveStageView(model: model) }

    func updateNSView(_ view: LiveStageView, context: Context) {
        let t = context.transaction
        view.update(self, animated: t.animation != nil && !t.disablesAnimations)
    }

    static func dismantleNSView(_ view: LiveStageView, coordinator: ()) { view.tearDown() }
}

// MARK: - Timing

/// A move's timing, as SwiftUI's were: a spring (`spring(duration:bounce:)`, `smooth`, `snappy`) or an ease, after a
/// delay.
struct StageCurve {
    enum Kind {
        case spring(Double, bounce: Double)
        case easeOut(Double)
        case easeInOut(Double)
    }

    var kind: Kind
    var delay = 0.0

    static func spring(_ duration: Double, bounce: Double) -> StageCurve { StageCurve(kind: .spring(duration, bounce: bounce)) }
    static func smooth(_ duration: Double) -> StageCurve { spring(duration, bounce: 0) }
    static func snappy(_ duration: Double) -> StageCurve { spring(duration, bounce: 0.15) }
    static func easeOut(_ duration: Double) -> StageCurve { StageCurve(kind: .easeOut(duration)) }
    static func easeInOut(_ duration: Double) -> StageCurve { StageCurve(kind: .easeInOut(duration)) }

    func delayed(_ seconds: Double) -> StageCurve {
        var c = self
        c.delay += seconds
        return c
    }

    /// How long until it's still, its delay included.
    var length: Double { delay + animation("opacity", from: 0, to: 1, on: nil).duration }

    /// An animation of `key` on this curve. Additive: from `from` (an offset from where it is now) to `to`
    /// (usually nothing), on top of the layer's own value and any other moves still running, so a move begun
    /// mid-move carries on from wherever it's drawn. Held at its start through the delay; `holds`, at its end
    /// after (for a tile leaving, until it's taken away).
    func animation(_ key: String, from: Any?, to: Any?, on layer: CALayer?, additive: Bool = false,
                   holds: Bool = false) -> CAAnimation {
        let a: CABasicAnimation
        switch kind {
        case let .spring(duration, bounce):
            let s = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
            s.duration = s.settlingDuration
            a = s
        case let .easeOut(duration):
            a = CABasicAnimation()
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        case let .easeInOut(duration):
            a = CABasicAnimation()
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        a.keyPath = key
        a.fromValue = from
        a.toValue = to
        a.isAdditive = additive
        if delay > 0, let layer {
            a.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        }
        a.fillMode = holds ? .both : .backwards
        if holds { a.isRemovedOnCompletion = false }
        return a
    }
}

/// Every key a tile's moves add under is new: additive moves run together (each a share of the way).
@MainActor private var moveCount = 0
@MainActor private func moveKey(_ name: String) -> String {
    moveCount &+= 1
    return "\(name).\(moveCount)"
}

// MARK: - The stage

final class LiveStageView: NSView {
    let model: AppModel
    private var shell: LiveStageShell?
    /// The tiles on the stage, by camera; and those leaving it (fading, receding), until they've gone.
    private var tiles: [String: StageTileView] = [:]
    private var leaving: [StageTileView] = []
    /// Tiles crossing to another row: over the others while they go.
    private var crossing: Set<String> = []
    /// The cameras as last laid out, and the size they were laid out for.
    private var lineup: [String] = []
    private var laidOut: CGSize = .zero
    /// What each tile shows, so a stand-in shows the same.
    private var statuses: [String: TileStatus] = [:]
    private var reportedStatuses: [String: TileStatus] = [:]

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func tearDown() {
        for tile in Array(tiles.values) + leaving { tile.stop() }
        tiles = [:]
        leaving = []
    }

    // MARK: Where tiles go

    private func frames(for ids: [String], in size: CGSize) -> [CGRect] {
        let area = CGSize(width: size.width - 2 * Stage.padding, height: size.height - 2 * Stage.padding)
        let (columns, tile) = Stage.layout(count: ids.count, in: area)
        return Stage.centres(count: ids.count, columns: columns, tile: tile, in: size).map {
            CGRect(x: $0.x - tile.width / 2, y: $0.y - tile.height / 2, width: tile.width, height: tile.height)
        }
    }

    // MARK: Told what to show

    func update(_ s: LiveStageShell, animated: Bool) {
        shell = s
        let ids = s.cameras.map(\.id)
        // Each tile's own (what it shows; its glow), whether or not the stage changes.
        for camera in s.cameras {
            let tile = tiles[camera.id] ?? makeTile(camera)
            tiles[camera.id] = tile
            give(tile, camera, s)
        }
        if laidOut == .zero || bounds.size == .zero {
            // The first layout: where they go, at once.
            lineup = ids
            if bounds.size != .zero { placeAll(curve: nil) }
            restack()
            return
        }
        if ids != lineup { change(from: lineup, to: ids, s) }
        restack()
    }

    private func makeTile(_ camera: Config.Camera) -> StageTileView {
        let tile = StageTileView(camera: camera, model: model, snapshots: shell?.snapshots, still: nil)
        tile.reported = { [weak self] id, status in self?.tileStatus(id, status) }
        addSubview(tile)
        return tile
    }

    private func give(_ tile: StageTileView, _ camera: Config.Camera, _ s: LiveStageShell) {
        let state = tile.state
        if state.camera != camera { state.camera = camera }
        let health = s.health[camera.id] ?? .ok
        if state.health != health { state.health = health }
        let events = s.activity[camera.id]
        if state.events != events { state.events = events }
        let many = s.cameras.count > 1
        if state.canRemove != many { state.canRemove = many }
        let announced = !tile.isLeaving && camera.id == s.justAdded
        let superseded = s.motion == .calm || (s.justAdded != nil && s.justAdded != camera.id)
        if state.superseded != superseded { state.superseded = superseded }
        if state.announced != announced { state.announced = announced }
        tile.actions = StageTileView.Actions(
            solo: many ? { [weak self] in self?.shell?.solo(camera.id) } : nil,
            remove: { [weak self] in self?.shell?.remove(camera.id) },
            openControls: { [weak self] in self?.shell?.openControls(camera.id) },
            openEvent: { [weak self] event in self?.shell?.openEvent(event) },
            soloAlways: { [weak self] in self?.shell?.solo(camera.id) },
            reorder: { [weak self] a, b in self?.shell?.reorder(a, b) })
        tile.drag = s.drag
        tile.reorderable = many
    }

    /// Who's in front: the camera grown to fill the stage, or those kept in front while others arrive; then the
    /// one just added; those leaving behind everything.
    private func restack() {
        guard let s = shell else { return }
        for (id, tile) in tiles {
            let z: CGFloat = s.motion == .focus(id) || s.inFront.contains(id) ? 2 : id == s.justAdded ? 1 : crossing.contains(id) ? 0.5 : 0
            if tile.layer?.zPosition != z { tile.layer?.zPosition = z }
        }
        for tile in leaving { tile.layer?.zPosition = -1 }
    }

    // MARK: Resized

    /// The stage is resized every frame while the dock or the rail moves (SwiftUI animates its layout), and as the
    /// window is resized: the tiles follow at once (a move under way carries on: it's added to where they are), their
    /// badges only carried to their corners; laid out again for their size once it's stopped changing.
    override func layout() {
        super.layout()
        guard bounds.size != laidOut, bounds.size != .zero, shell != nil else { return }
        let was = laidOut
        laidOut = bounds.size
        let frames = frames(for: lineup, in: bounds.size)
        let before = columns(lineup.count, in: was), after = columns(lineup.count, in: bounds.size)
        if was != .zero, before != after {
            reflow(frames, from: before, to: after)
        } else {
            for (i, id) in lineup.enumerated() {
                tiles[id]?.place(frames[i], curve: nil, following: true)
            }
        }
        let id = UUID()
        settling = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.settling == id else { return }
            self.settling = nil
            for tile in self.tiles.values { tile.settle() }
        }
    }

    private var settling: UUID?

    private func columns(_ count: Int, in size: CGSize) -> Int {
        Stage.layout(count: count, in: CGSize(width: size.width - 2 * Stage.padding, height: size.height - 2 * Stage.padding)).columns
    }

    /// The stage's new size takes another number of columns (the rail coming or going, the window resized past
    /// a size): the tiles reflow, not snap, each moving to its new place as one piece (those changing rows over the
    /// others). On the side panels' curve; the frames after follow at once, carried on top.
    private func reflow(_ frames: [CGRect], from before: Int, to after: Int) {
        CATransaction.begin()
        var crossers: [String] = []
        for (i, id) in lineup.enumerated() {
            if i / before != i / after { crossers.append(id) }
            tiles[id]?.place(frames[i], curve: Self.reflowCurve)
        }
        cross(crossers, for: Self.reflowCurve.length)
        CATransaction.commit()
    }

    /// Tiles crossing to another row go over the others (not under them) while they move.
    private func cross(_ ids: [String], for seconds: Double) {
        guard !ids.isEmpty else { return }
        crossing.formUnion(ids)
        restack()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.crossing.subtract(ids)
            self.restack()
        }
    }

    /// The springs' bounce, a little less than SwiftUI's stage had (0.3, 0.35, 0.15): changes in quick succession were
    /// too lively.
    static let livelyBounce = 0.22, popBounce = 0.27, calmBounce = 0.1

    /// The side panels' curve (`LiveView.dockAnimation`).
    static let reflowCurve = StageCurve.spring(0.42, bounce: 0.12)

    private func placeAll(curve: StageCurve?) {
        laidOut = bounds.size
        let frames = frames(for: lineup, in: bounds.size)
        for (i, id) in lineup.enumerated() {
            tiles[id]?.place(frames[i], curve: curve)
        }
    }

    // MARK: A change

    private func change(from old: [String], to new: [String], _ s: LiveStageShell) {
        let size = bounds.size
        laidOut = size
        let oldFrames = frames(for: old, in: size)
        let newFrames = frames(for: new, in: size)
        lineup = new
        let removed = old.filter { !new.contains($0) }
        let inserted = Set(new.filter { !old.contains($0) })
        let motion = s.motion
        let stageCentre = CGPoint(x: size.width / 2, y: size.height / 2)
        // Tiles that change rows: moved as the others are (one piece, from where it's drawn, whatever it's in the
        // middle of), over them. (SwiftUI's stage faded these across in a quick run of changes.)
        let area = CGSize(width: size.width - 2 * Stage.padding, height: size.height - 2 * Stage.padding)
        let rowChanges = Stage.rowChanges(from: old, to: new, area: area, size: size)

        // The curve the tiles staying move on.
        func move(_ index: Int) -> StageCurve? {
            switch motion {
            case .lively:
                StageCurve.spring(0.5, bounce: Self.livelyBounce).delayed((s.afterRemoval ? Stage.removeLead : 0) + Double(index) * Stage.ripple)
            case .calm: .spring(0.46, bounce: Self.calmBounce)
            case .reorder: .snappy(0.3)
            case .reveal: .smooth(0.4)
            case .swap: nil
            case .focus: .smooth(0.4)
            case .crossfade: .smooth(0.25)
            }
        }

        CATransaction.begin()
        // The tiles leaving.
        for (i, id) in old.enumerated() where removed.contains(id) {
            guard let tile = tiles.removeValue(forKey: id) else { continue }
            tile.isLeaving = true
            tile.recheckHover()
            tile.state.announced = false
            leaving.append(tile)
            let frame = oldFrames[i]
            switch motion {
            case .swap:
                letGo(tile)
            case .focus:
                tile.leave(curve: .easeInOut(0.25), scale: 1, shift: .zero, after: 0.25) { [weak self] in self?.letGo(tile) }
            case .crossfade:
                // Every leaving tile shrinks by the same amount and moves the same share of the way to the stage's
                // centre, so the stage recedes as one, gutters and all.
                let k = LiveView.recedeScale
                let shift = CGSize(width: (k - 1) * (frame.midX - stageCentre.x), height: (k - 1) * (frame.midY - stageCentre.y))
                tile.leave(curve: .smooth(0.25), scale: k, shift: shift, after: 0.35) { [weak self] in self?.letGo(tile) }
            case .reveal:
                tile.leave(curve: .easeOut(0.16), scale: 1, shift: .zero, after: 0.16) { [weak self] in self?.letGo(tile) }
            case .lively, .calm, .reorder:
                tile.leave(curve: .easeOut(0.16), scale: 0.9, shift: .zero, after: 0.16) { [weak self] in self?.letGo(tile) }
            }
        }
        // The tiles staying, and those arriving.
        for (i, id) in new.enumerated() {
            guard let tile = tiles[id] else { continue }
            let frame = newFrames[i]
            if inserted.contains(id) {
                tile.place(frame, curve: nil)
                switch motion {
                case .swap: break
                case .reveal:
                    tile.arrive(curve: StageCurve.smooth(0.35).delayed(0.08 + Double(i) * Stage.revealStagger), scale: 0.92)
                case .lively:
                    tile.arrive(curve: StageCurve.spring(0.45, bounce: Self.popBounce).delayed(Stage.insertDelay), scale: 0.6)
                case .calm, .reorder:
                    tile.arrive(curve: StageCurve.spring(0.25, bounce: 0).delayed(0.12), scale: 0.9)
                case .focus:
                    tile.arrive(curve: .easeInOut(0.25), scale: 1)
                case .crossfade:
                    // Grown by as much as the old stage recedes, once it's nearly gone.
                    tile.arrive(curve: StageCurve.smooth(0.4).delayed(LiveView.arriveDelay), scale: LiveView.recedeScale)
                }
            } else {
                tile.place(frame, curve: move(i))
            }
        }
        if let curve = move(0) { cross(Array(rowChanges.keys), for: curve.length + Double(new.count) * Stage.ripple) }
        CATransaction.commit()
    }

    private func letGo(_ tile: StageTileView) {
        tile.stop()
        tile.removeFromSuperview()
        leaving.removeAll { $0 === tile }
        statusesChanged()
    }

    // MARK: What the tiles show

    private func tileStatus(_ id: String, _ status: TileStatus?) {
        if let status { statuses[id] = status }
        statusesChanged()
    }

    /// Told on: every tile's status (those leaving too, while they're there), as `TileStatuses` gathered them.
    private func statusesChanged() {
        var now: [String: TileStatus] = [:]
        for tile in leaving + Array(tiles.values) {
            if let status = tile.status { now[tile.state.camera.id] = status }
        }
        guard now != reportedStatuses else { return }
        reportedStatuses = now
        // (Not in the middle of SwiftUI's update.)
        DispatchQueue.main.async { [weak self] in self?.shell?.statuses(now) }
    }
}

// MARK: - A tile

/// What a tile's badges and buttons show, watched by them (SwiftUI) and by the tile.
@MainActor
@Observable
final class StageTileState {
    var camera: Config.Camera
    var compact = false
    var cornerRadius = 16.0
    var pointerInside = false
    /// A popover from it is open (its events, its HomeKit badge): it has the pointer, so the controls stay.
    var popoverOpen = false
    var hovering: Bool { pointerInside || popoverOpen }
    /// A still stand-in: no connection, its picture, and this status.
    var frozen: TileStatus?
    var health = CameraHealth.ok
    var events: CameraActivity.Summary?
    var canRemove = false
    var stream: LiveStream?
    var noPassword = false
    var announced = false
    var superseded = false
    /// The buttons along the bottom right, and how wide they are (the name's room is what's left).
    var trailingWidth = 0.0

    init(camera: Config.Camera) { self.camera = camera }

    func status(_ model: AppModel) -> TileStatus {
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
}

final class StageTileView: NSView {
    struct Actions {
        var solo: (() -> Void)?
        var remove: () -> Void = {}
        var openControls: () -> Void = {}
        var openEvent: (TimelineEvent) -> Void = { _ in }
        /// Watches it alone (double-click, its menu), whether or not others are on the stage.
        var soloAlways: () -> Void = {}
        var reorder: (String, String) -> Void = { _, _ in }
    }

    let model: AppModel
    let state: StageTileState
    var actions = Actions()
    let snapshots: CameraSnapshots?
    var drag: ReorderDrag? {
        didSet { if drag !== oldValue { refresh() } }
    }
    var reorderable = false
    /// Told what it shows, as it changes.
    var reported: (String, TileStatus?) -> Void = { _, _ in }
    private(set) var status: TileStatus?
    var isLeaving = false

    /// Everything but the moves and comings and goings (which are the tile's own layer's): dimmed while it's
    /// dragged.
    private let body = FlippedView()
    /// The picture, clipped to the tile's corner: black, its last snapshot, its video, the corner darkened.
    private let picture = FlippedView()
    private let still = CALayer()
    private let cornerShade = CAGradientLayer()
    private let topShade = CAGradientLayer()
    private let bottomShade = CAGradientLayer()
    /// Over the badges: a picture taken's flash, the edge in the health's colour; and the glow round it, just added.
    private let over = InertView()
    private let flash = CALayer()
    private let edge = CALayer()
    private let ring = CALayer()
    private let ringGlow = CALayer()
    /// Its badges and buttons, each hosted at its corner: those it needs at once (its name, its message) made with
    /// it, the others a moment after it's settled, or when first wanted (the pointer on it).
    private var hosts: [Pin: ChromeHost] = [:]
    /// The stream's views: the current one and the one taking over (each kept all along).
    private var videos: [ObjectIdentifier: AVSampleBufferDisplayLayer] = [:]

    /// The stream taking over (the tile grew or shrank past the main stream's size), and whether it's been faded in.
    private var incoming: LiveStream?
    private var incomingShown = false
    private var player: Task<Void, Never>?
    private var playingKey: String?
    private var watching: Watching?
    private var shownPrivate: Bool?
    private var flashed = false
    private var glowing: Bool?
    private var mainStream = false
    private var stillImage: CGImage?

    enum Pin: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing, centre, topCentre
    }

    init(camera: Config.Camera, model: AppModel, snapshots: CameraSnapshots?, still frozen: (image: CGImage?, status: TileStatus)?) {
        self.model = model
        self.snapshots = snapshots
        state = StageTileState(camera: camera)
        super.init(frame: .zero)
        wantsLayer = true
        if let frozen {
            state.frozen = frozen.status
            stillImage = frozen.image
            still.contents = frozen.image
        }
        for view in [body, picture, over] {
            view.wantsLayer = true
        }
        addSubview(body)
        body.addSubview(picture)
        let clip = picture.layer!
        clip.backgroundColor = .black
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        still.contentsGravity = .resizeAspect
        still.anchorPoint = .zero
        clip.addSublayer(still)
        // The bottom-left corner darkened softly, under the name and badges there, so they read on any picture.
        cornerShade.type = .radial
        cornerShade.colors = [CGColor(gray: 0, alpha: 0.38), CGColor(gray: 0, alpha: 0.12), CGColor(gray: 0, alpha: 0)]
        cornerShade.startPoint = CGPoint(x: 0.5, y: 0.5)
        cornerShade.endPoint = CGPoint(x: 1, y: 1)
        // Hovered: the top and bottom edges darkened a little, so the controls there stand out from the video.
        topShade.colors = [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)]
        bottomShade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.5)]
        for shade in [cornerShade, topShade, bottomShade] {
            shade.anchorPoint = .zero
            clip.addSublayer(shade)
        }
        topShade.opacity = 0
        bottomShade.opacity = 0
        body.addSubview(over)
        let top = over.layer!
        flash.backgroundColor = .white
        flash.opacity = 0
        flash.cornerCurve = .continuous
        edge.cornerCurve = .continuous
        edge.borderWidth = 2
        for layer in [flash, edge, ringGlow, ring] {
            layer.anchorPoint = .zero
            top.addSublayer(layer)
        }
        // The glow round a camera just added: an accent ring that glows up and settles.
        for (layer, radius, alpha) in [(ring, 14.0, 0.9), (ringGlow, 28.0, 0.5)] {
            layer.cornerCurve = .continuous
            layer.borderWidth = 3
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = Float(alpha)
            layer.shadowOffset = .zero
            layer.shadowRadius = radius
            layer.opacity = 0
        }
        build(.centre)
        build(.bottomLeading)
        if frozen == nil {
            // The rest, once it's arrived: one a turn, so a dozen arriving together aren't all made in one frame.
            var later = Pin.allCases.filter { hosts[$0] == nil }
            func next() {
                DispatchQueue.main.asyncAfter(deadline: .now() + (later.count == 4 ? 0.9 : 0.03)) { [weak self] in
                    guard let self, !later.isEmpty, self.watching != nil else { return }
                    self.build(later.removeFirst())
                    next()
                }
            }
            next()
        }
        updateTrackingAreas()
        registerForDraggedTypes([.string])
        watching = Watching { [weak self] in self?.render() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Its badges and buttons

    /// Bottom to top (all under the flash and the edge, but the "Added" chip).
    private static let order: [Pin] = [.centre, .bottomLeading, .bottomTrailing, .topTrailing, .topLeading, .topCentre]

    /// Makes the badges or buttons at `pin`, if they aren't yet.
    private func build(_ pin: Pin) {
        guard hosts[pin] == nil else { return }
        let host = ChromeHost()
        hosts[pin] = host
        let s = state
        func content(_ view: some View) {
            host.rootView = AnyView(view.chromeHits { [weak host] in host?.clickable = $0 }.environment(model))
        }
        switch pin {
        case .bottomLeading: content(TileNameRow(state: s))
        case .bottomTrailing: content(TileTrailingRow(state: s))
        case .topTrailing: content(TileCornerButtons(state: s, actions: { [weak self] in self?.actions ?? Actions() }))
        case .topLeading: content(TileTopLeading(state: s, open: { [weak self] in self?.actions.openEvent($0) }))
        case .centre:
            content(TileStatusMessage(state: s))
        case .topCentre: content(TileAddedChip(state: s))
        }
        host.wantsLayer = true
        host.frame = hostFrame(pin, in: bounds.size)
        if pin == .topCentre {
            body.addSubview(host)
        } else if let above = Self.order.drop(while: { $0 != pin }).dropFirst().compactMap({ hosts[$0] }).first(where: { $0.superview === body && hosts[.topCentre] !== $0 }) {
            body.addSubview(host, positioned: .below, relativeTo: above)
        } else {
            body.addSubview(host, positioned: .below, relativeTo: over)
        }
    }

    /// Where the badges or buttons at `pin` go on a tile of this size.
    private func hostFrame(_ pin: Pin, in size: CGSize) -> CGRect {
        let compact = size.height < Stage.compactHeight
        let pad = compact ? 7.0 : 10
        let corner = compact ? 6.0 : 10
        let row = compact ? CameraTile.compactPillHeight : CameraTile.pillHeight
        switch pin {
        case .bottomLeading, .bottomTrailing:
            return CGRect(x: pad, y: size.height - pad - row, width: max(0, size.width - 2 * pad), height: row)
        case .topTrailing:
            return CGRect(x: corner, y: corner, width: max(0, size.width - 2 * corner), height: row)
        case .topLeading:
            // (Its health, and its events under it.)
            return CGRect(x: corner, y: corner, width: max(0, size.width - 2 * corner), height: 2 * row + 12)
        case .centre:
            return CGRect(origin: .zero, size: size)
        case .topCentre:
            return CGRect(x: 0, y: 10, width: size.width, height: 40)
        }
    }

    /// The badges at their corners for the tile's size: laid out for it, or (`following` a resize, frame by frame)
    /// only carried there, at the size they have.
    private func layHosts(_ size: CGSize, following: Bool) {
        for (pin, host) in hosts {
            let target = hostFrame(pin, in: size)
            guard following, host.frame.size != .zero else {
                if host.frame != target { host.frame = target }
                continue
            }
            let w = host.frame.width, h = host.frame.height
            let x = switch pin {
            case .topLeading, .bottomLeading: target.minX
            case .topTrailing, .bottomTrailing: target.maxX - w
            case .centre, .topCentre: target.midX - w / 2
            }
            let y = switch pin {
            case .topLeading, .topTrailing, .topCentre: target.minY
            case .bottomLeading, .bottomTrailing: target.maxY - h
            case .centre: target.midY - h / 2
            }
            host.setFrameOrigin(CGPoint(x: x, y: y))
        }
    }

    /// The resizing's stopped: the badges laid out for the size it is.
    func settle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layHosts(bounds.size, following: false)
        CATransaction.commit()
        recheckHover()
    }

    // MARK: Where it is

    /// Puts the tile at `frame`, moving there on `curve` from where it's drawn now (at once without one).
    func place(_ frame: CGRect, curve: StageCurve?, following: Bool = false) {
        let old = self.frame
        let compact = frame.height < Stage.compactHeight
        let corner = frame.width > 600 ? 22.0 : 16
        if state.compact != compact { state.compact = compact }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        lay(frame.size, corner: corner, following: following)
        CATransaction.commit()
        if state.cornerRadius != corner { state.cornerRadius = corner }
        if old != frame {
            recheckHover()
            if let curve { DispatchQueue.main.asyncAfter(deadline: .now() + curve.length) { [weak self] in self?.recheckHover() } }
        }
        // (Drawn again only for a change of stream: following a resize, frame by frame, nothing else changes.)
        let main = frame.width >= Stage.mainStreamWidth
        if main != mainStream || old.size == .zero {
            mainStream = main
            refresh()
        }
        guard let curve, old.size != .zero, old != frame, let layer else { return }
        // The tile from where it was (its own layer), its picture and everything sized with it from its old size,
        // its badges from their old corners: all on one curve, begun together.
        let moved = GridHostView.moving(layer, from: frame, to: old, scale: 1)
        layer.add(curve.animation("transform.translation", from: NSValue(size: CGSize(width: moved.m41, height: moved.m42)),
                                  to: NSValue(size: .zero), on: layer, additive: true), forKey: moveKey("move"))
        let grow = CGSize(width: old.width - frame.width, height: old.height - frame.height)
        for sized in sizedLayers {
            sized.add(curve.animation("bounds.size", from: NSValue(size: grow), to: NSValue(size: .zero), on: sized, additive: true),
                      forKey: moveKey("size"))
        }
        for video in videos.values {
            video.add(curve.animation("transform.scale", from: grow.width / Self.videoWidth, to: 0, on: video, additive: true),
                      forKey: moveKey("size"))
        }
        for (pinned, pin) in pinnedLayers {
            let d = offset(pin, from: old.size, to: frame.size, in: pinned.superlayer)
            guard d != .zero else { continue }
            pinned.add(curve.animation("transform.translation", from: NSValue(size: d), to: NSValue(size: .zero), on: pinned,
                                       additive: true), forKey: moveKey("pin"))
        }
        for (pin, host) in hosts {
            guard let hostLayer = host.layer else { continue }
            let d = offset(pin, from: old.size, to: frame.size, in: hostLayer.superlayer)
            guard d != .zero else { continue }
            hostLayer.add(curve.animation("transform.translation", from: NSValue(size: d), to: NSValue(size: .zero), on: hostLayer,
                                          additive: true), forKey: moveKey("pin"))
        }
        let oldCorner = old.width > 600 ? 22.0 : 16
        if oldCorner != corner {
            for cornered in corneredLayers {
                cornered.add(curve.animation("cornerRadius", from: cornered.presentation()?.cornerRadius ?? oldCorner,
                                             to: corner, on: cornered), forKey: "corner")
            }
        }
    }

    /// Layers the tile's size (they grow and shrink with it).
    private var sizedLayers: [CALayer] {
        [picture.layer, still, over.layer, flash, edge, ring, ringGlow].compactMap { $0 }
    }

    /// The video's own size, whatever the tile's: never resized (resized, it drew its picture catching up with the
    /// tile, a moment behind), only scaled to the tile (16:9, as every tile is).
    static let videoWidth = 1600.0

    private func scaleVideo(_ video: CALayer, to size: CGSize) {
        video.bounds = CGRect(x: 0, y: 0, width: Self.videoWidth, height: Self.videoWidth * 9 / 16)
        video.position = .zero
        let k = size.width / Self.videoWidth
        video.transform = CATransform3DMakeScale(k, k, 1)
    }

    /// Layers kept at a corner or edge (they move with it, and keep their size).
    private var pinnedLayers: [(CALayer, Pin)] {
        [(cornerShade, .bottomLeading), (bottomShade, .bottomLeading)]
    }

    private var corneredLayers: [CALayer] { [picture.layer, flash, edge, ring, ringGlow].compactMap { $0 } }

    /// How far a point pinned at `pin` was from where it is now, in `container`'s own terms (drawn top down, or not).
    private func offset(_ pin: Pin, from old: CGSize, to new: CGSize, in container: CALayer?) -> CGSize {
        func point(_ size: CGSize) -> CGPoint {
            switch pin {
            case .topLeading: CGPoint(x: 0, y: 0)
            case .topTrailing: CGPoint(x: size.width, y: 0)
            case .bottomLeading: CGPoint(x: 0, y: size.height)
            case .bottomTrailing: CGPoint(x: size.width, y: size.height)
            case .centre: CGPoint(x: size.width / 2, y: size.height / 2)
            case .topCentre: CGPoint(x: size.width / 2, y: 0)
            }
        }
        // (Origin at the bottom, the tile's top moves with its height; a size-wide layer grows upward.)
        let down = container?.contentsAreFlipped() ?? true
        func inLayer(_ p: CGPoint, _ size: CGSize) -> CGPoint { down ? p : CGPoint(x: p.x, y: size.height - p.y) }
        let a = inLayer(point(old), old), b = inLayer(point(new), new)
        return CGSize(width: a.x - b.x, height: a.y - b.y)
    }

    /// Everything inside at its place for the tile's (final) size.
    private func lay(_ size: CGSize, corner: Double, following: Bool) {
        let full = CGRect(origin: .zero, size: size)
        body.frame = full
        picture.frame = full
        over.frame = full
        for layer in [still, flash, edge, ring, ringGlow] { layer.frame = full }
        for video in videos.values { scaleVideo(video, to: size) }
        for layer in corneredLayers { layer.cornerRadius = corner }
        let compact = size.height < Stage.compactHeight
        // (A layer drawn bottom up has its origin at the bottom.)
        let down = picture.layer?.contentsAreFlipped() ?? true
        func rect(_ r: CGRect) -> CGRect { down ? r : CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
        let radius = compact ? 170.0 : 280
        cornerShade.frame = rect(CGRect(x: -radius, y: size.height - radius, width: 2 * radius, height: 2 * radius))
        // As wide as any tile (clipped to this one): no width to follow as it grows.
        let wide = 8000.0
        topShade.frame = rect(CGRect(x: 0, y: 0, width: wide, height: compact ? 44 : 72))
        let bottom = compact ? 52.0 : 84
        bottomShade.frame = rect(CGRect(x: 0, y: size.height - bottom, width: wide, height: bottom))
        // Top to bottom on the tile, whichever way the layer's drawn (a gradient's points are from the bottom unless
        // it's flipped: taken as from the top, each ran the wrong way, dark at its inner edge, ending in a hard line).
        for shade in [topShade, bottomShade] {
            let top = shade.contentsAreFlipped() ? 0.0 : 1
            shade.startPoint = CGPoint(x: 0.5, y: top)
            shade.endPoint = CGPoint(x: 0.5, y: 1 - top)
        }
        for video in videos.values { fitVideo(video, in: size) }
        // The badges and buttons: each at its corner, at its own size (laid out once, for the final size).
        layHosts(size, following: following)
    }

    private func fitVideo(_ video: AVSampleBufferDisplayLayer, in size: CGSize) {
        guard let stream = [state.stream, incoming].compactMap({ $0 }).first(where: { $0.layer === video }),
              let videoSize = stream.size, videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else { return }
        let picture = videoSize.width / videoSize.height, tile = size.width / size.height
        let gravity: AVLayerVideoGravity = abs(picture / tile - 1) <= VideoLayerView.HostView.fillTolerance ? .resizeAspectFill : .resizeAspect
        // (At once: changed in an animated transaction, the picture inside was drawn sliding and growing to its place.)
        guard video.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.videoGravity = gravity
        CATransaction.commit()
    }

    // MARK: Coming and going

    /// Arriving: grown from `scale` about its centre, fading in, on `curve`.
    func arrive(curve: StageCurve, scale: Double) {
        guard let layer else { return }
        let c = centreFromAnchor(layer)
        if scale != 1 {
            layer.add(curve.animation("transform.scale", from: scale - 1, to: 0, on: layer, additive: true), forKey: moveKey("arrive"))
            layer.add(curve.animation("transform.translation", from: NSValue(size: CGSize(width: c.width * (1 - scale), height: c.height * (1 - scale))),
                                      to: NSValue(size: .zero), on: layer, additive: true), forKey: moveKey("arrive"))
        }
        layer.add(curve.animation("opacity", from: 0, to: 1, on: layer), forKey: "fade")
        layer.opacity = 1
    }

    /// The tile's centre from the point its layer scales about.
    private func centreFromAnchor(_ layer: CALayer) -> CGSize {
        CGSize(width: bounds.width * (0.5 - layer.anchorPoint.x), height: bounds.height * (0.5 - layer.anchorPoint.y))
    }

    /// Leaving: shrinking to `scale` about its centre and moving by `shift`, fading out, on `curve`; then `done`.
    func leave(curve: StageCurve, scale: Double, shift: CGSize, after: Double, done: @escaping @MainActor () -> Void) {
        guard let layer else { return done() }
        let c = centreFromAnchor(layer)
        let down = layer.superlayer?.contentsAreFlipped() ?? true
        let move = CGSize(width: c.width * (1 - scale) + shift.width, height: c.height * (1 - scale) + (down ? shift.height : -shift.height))
        if scale != 1 {
            layer.add(curve.animation("transform.scale", from: 0, to: scale - 1, on: layer, additive: true, holds: true), forKey: "leave.scale")
        }
        if move != .zero {
            layer.add(curve.animation("transform.translation", from: NSValue(size: .zero), to: NSValue(size: move), on: layer,
                                      additive: true, holds: true), forKey: "leave.move")
        }
        layer.add(curve.animation("opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: 0, on: layer, holds: true), forKey: "fade")
        layer.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { done() }
    }

    // MARK: Drawn from what it shows

    /// What it shows, from the camera's state, its stream's and its own: watched, so drawn again whenever any of
    /// it changes.
    private func render() {
        let s = state
        let id = s.camera.id
        let hidden = model.isPrivate(id)
        let status = s.status(model)
        let playing = status == .playing
        // The picture: its last snapshot, whole, dimmed behind a message (a stand-in for a playing tile shows it
        // plainly); private, not even that.
        let image = s.frozen != nil ? stillImage : snapshots?[id]?.image
        let showsStill = image != nil && (!playing || s.frozen != nil) && status != .keptPrivate
        if s.frozen == nil, stillImage !== image {
            stillImage = image
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            still.contents = image
            CATransaction.commit()
        }
        let animatePrivacy = shownPrivate != nil && shownPrivate != hidden
        shownPrivate = hidden
        change(still, "opacity", to: Float(showsStill ? (playing ? 1 : 0.35) : 0), animated: animatePrivacy)
        // The streams: shown once playing; the one taking over all but unseen (but drawing) till it's faded in.
        if s.frozen == nil {
            for stream in [s.stream, incoming].compactMap({ $0 }) {
                let video = stream.layer
                let alpha: Float = stream.state == .playing && !hidden ? (stream === incoming && !incomingShown ? 0.001 : 1) : 0
                change(video, "opacity", to: alpha, animated: animatePrivacy)
                _ = stream.size
            }
            for video in videos.values { fitVideo(video, in: bounds.size) }
        }
        // Badges wanted now that aren't made yet: made (out of this drawing).
        let wanted: [Pin] = (s.hovering ? [.topTrailing, .bottomTrailing, .topLeading] : [])
            + (s.health.showsBadge ? [.topLeading] : []) + (s.announced ? [.topCentre] : [])
            + (model.audibleCamera == id || model.talking?.camera == id ? [.bottomTrailing] : [])
        if s.frozen == nil, wanted.contains(where: { hosts[$0] == nil }) {
            DispatchQueue.main.async { [weak self] in for pin in wanted { self?.build(pin) } }
        }
        // Hovered: the edges darkened.
        let shaded: Float = s.hovering && s.frozen == nil ? 1 : 0
        if topShade.opacity != shaded {
            GridCardView.change(topShade, "opacity", to: shaded, animated: true, duration: 0.15)
            GridCardView.change(bottomShade, "opacity", to: shaded, animated: true, duration: 0.15)
        }
        // Something wrong, or private: its edge in the health's colour.
        let edgeColour = s.health.showsEdge ? NSColor(s.health.tint).withAlphaComponent(0.7).cgColor : CGColor.clear
        change(edge, "borderColor", to: edgeColour, animated: false)
        // A picture taken: a quick flash, as a shutter.
        let flashing = model.flash == id
        if flashing != flashed {
            flashed = flashing
            GridCardView.change(flash, "opacity", to: Float(flashing ? 0.55 : 0), animated: true, duration: flashing ? 0.05 : 0.35)
        }
        // Just added: the glow, lit once the tiles have nearly settled; gone at once for another, slowly else.
        if glowing != s.announced {
            let first = glowing == nil
            glowing = s.announced
            for (layer, radius) in [(ring, 14.0), (ringGlow, 28.0)] {
                let curve: StageCurve = s.announced ? StageCurve.spring(0.5, bounce: 0.35).delayed(0.6)
                    : s.superseded ? .easeOut(0.15) : .easeOut(0.6)
                if !first {
                    layer.add(curve.animation("opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: s.announced ? 1 : 0, on: layer),
                              forKey: "glow")
                    layer.add(curve.animation("shadowRadius", from: layer.presentation()?.shadowRadius ?? layer.shadowRadius,
                                              to: s.announced ? radius : 0, on: layer), forKey: "glow.radius")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = s.announced ? 1 : 0
                layer.shadowRadius = s.announced ? radius : 0
                CATransaction.commit()
            }
        }
        // Its drag: dimmed while it's dragged; another Pond's step back.
        if let drag {
            let apart = drag.camera.map { ReorderDrag.group(of: $0) != ReorderDrag.group(of: id) } ?? false
            change(body.layer!, "opacity", to: Float(drag.camera == id ? 0.45 : apart ? 0.35 : 1), animated: true, duration: 0.15)
        }
        // The stream: run while the tile's here, for its camera, its size and its privacy.
        if s.frozen == nil {
            let c = s.camera
            let key = "\(c.id) \(c.main) \(c.sub) \(c.username) \(mainStream) \(hidden)"
            if key != playingKey {
                playingKey = key
                player?.cancel()
                player = Task { [weak self] in
                    guard let self else { return }
                    // Private: not connected at all (once the picture has faded).
                    guard !hidden else {
                        try? await Task.sleep(for: .seconds(0.4))
                        if !Task.isCancelled { self.stopStreams() }
                        return
                    }
                    await self.play()
                }
            }
            s.stream?.muted = !(model.audibleCamera == id) || s.stream === incoming
            s.stream?.retriesSoon = model.isWaking(id)
        }
        if s.frozen == nil, self.status != status {
            self.status = status
            reported(id, status)
        }
    }

    /// Drawn again now, and watched again (for what it reads now that it didn't before).
    private func refresh() {
        watching?.again()
    }

    private func change(_ layer: CALayer, _ key: String, to value: Any, animated: Bool, duration: Double = 0.3) {
        if let now = layer.value(forKeyPath: key), (now as? NSObject)?.isEqual(value) == true { return }
        if key == "opacity", let now = layer.value(forKeyPath: key) as? Float, let to = value as? Float, now == to { return }
        GridCardView.change(layer, key, to: value, animated: animated, duration: duration)
    }

    // MARK: The stream

    /// Runs the stream while the tile is on screen (as `CameraTile.play`).
    private func play() async {
        let camera = state.camera
        guard model.hasPassword(camera.id) else {
            state.noPassword = true
            return
        }
        state.noPassword = false
        let s = LiveStream(url: mainStream ? camera.main : camera.sub, relay: model.streamRelay)
        s.retriesSoon = model.isWaking(camera.id)
        s.muted = model.audibleCamera != camera.id
        // This camera's other stream (main or sub), already playing, stays the picture until this one plays.
        let previous = state.stream.flatMap { old in
            old.state == .playing && [camera.main, camera.sub].contains(old.url) ? old : nil
        }
        if let incoming { drop(incoming) }
        incoming = nil
        incomingShown = false
        if let previous {
            s.muted = true
            incoming = s
            show(s)
            s.start()
            // Up to a few seconds for its first picture, and not before the tile has stopped growing or shrinking;
            // then faded in over the old one (whole underneath), which then stops.
            let started = Date()
            for _ in 0 ..< 100 where (s.state != .playing || Date().timeIntervalSince(started) < CameraTile.settle) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if incoming === s {
                incomingShown = true
                GridCardView.change(s.layer, "opacity", to: Float(s.state == .playing && !model.isPrivate(camera.id) ? 1 : 0),
                                    animated: true, duration: CameraTile.crossfade)
                try? await Task.sleep(for: .seconds(CameraTile.crossfade))
                if incoming === s {
                    s.muted = model.audibleCamera != camera.id
                    state.stream = s
                    incoming = nil
                    incomingShown = false
                    model.liveFeeds[camera.id] = s
                    drop(previous)
                    refresh()
                }
            }
        } else {
            if let old = state.stream { drop(old) }
            state.stream = s
            show(s)
            s.start()
            model.liveFeeds[camera.id] = s
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// A stream's view in the tile, under the darkened corner, its size the tile's.
    private func show(_ stream: LiveStream) {
        let video = stream.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.anchorPoint = .zero
        scaleVideo(video, to: bounds.size)
        video.opacity = 0
        picture.layer?.insertSublayer(video, below: cornerShade)
        videos[ObjectIdentifier(video)] = video
        fitVideo(video, in: bounds.size)
        CATransaction.commit()
        refresh()
    }

    private func drop(_ stream: LiveStream) {
        stream.stop()
        stream.layer.removeFromSuperlayer()
        videos[ObjectIdentifier(stream.layer)] = nil
    }

    private func stopStreams() {
        if let stream = state.stream, model.liveFeeds[state.camera.id] === stream { model.liveFeeds[state.camera.id] = nil }
        if let stream = state.stream { drop(stream) }
        if let incoming { drop(incoming) }
        state.stream = nil
        incoming = nil
        incomingShown = false
    }

    /// Taken off the screen: its streams stop, and it's no longer watched.
    func stop() {
        player?.cancel()
        player = nil
        watching?.stop()
        watching = nil
        stopStreams()
    }

    // MARK: The pointer

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    // Only its own: the hosted badges' own tracking (SwiftUI's hover) is passed up here too as they're crossed, and
    // taken for the tile's, the controls came and went by zones.
    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        recheckHover()
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
        recheckHover()
    }

    /// Whether the pointer's on it, from where the pointer is: on entering and leaving, and after the tile's moved
    /// (moving under a still pointer, a view isn't told).
    func recheckHover() {
        var inside = false
        if !isLeaving, state.frozen == nil, let window, NSApp.isActive {
            inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        if state.pointerInside != inside { state.pointerInside = inside }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isLeaving, state.frozen == nil else { return nil }
        return super.hitTest(point)
    }

    private var pressedAt: NSPoint?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return actions.soloAlways() }
        pressedAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard reorderable, let start = pressedAt, let drag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        pressedAt = nil
        _ = drag.begin(state.camera.id, from: .stage)
        let item = NSPasteboardItem()
        item.setString(state.camera.id, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let preview = ImageRenderer(content: DragPreview(name: state.camera.name))
        preview.scale = window?.backingScaleFactor ?? 2
        if let image = preview.nsImage {
            let at = convert(event.locationInWindow, from: nil)
            dragging.setDraggingFrame(CGRect(x: at.x - image.size.width / 2, y: at.y - image.size.height / 2,
                                             width: image.size.width, height: image.size.height), contents: image)
        }
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isLeaving, state.frozen == nil else { return nil }
        let id = state.camera.id
        let own = model.ownCamera(id) != nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        item("Watch Only This") { [weak self] in self?.actions.soloAlways() }
        menu.addItem(.separator())
        item("Camera Settings\u{2026}", symbol: "gearshape", enabled: own) { [weak self] in self?.model.editCameraSettings(id) }
        item("Edit Zones\u{2026}", symbol: "square.dashed", enabled: model.canEditZones(id)) { [weak self] in self?.model.editZones(id) }
        item("Doctor\u{2026}", symbol: "stethoscope", enabled: own) { [weak self] in self?.model.showDoctor(camera: id) }
        return menu
    }
}

// MARK: Dragged into a new order

extension StageTileView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private var dropEnabled: Bool {
        guard reorderable, !isLeaving, let dragged = drag?.camera else { return false }
        return ReorderDrag.group(of: dragged) == ReorderDrag.group(of: state.camera.id)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropEnabled, let drag else { return [] }
        drag.over = state.camera.id
        drag.moveIfSettled(actions.reorder)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropEnabled, let drag else { return [] }
        // Called as the pointer moves: catches up with a camera entered while things were settling.
        drag.moveIfSettled(actions.reorder)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if drag?.over == state.camera.id { drag?.over = nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard drag?.camera != nil else { return false }
        drag?.camera = nil
        drag?.source = nil
        drag?.over = nil
        return true
    }
}

/// A view that's drawn but takes no clicks (they go to what's under it).
final class InertView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Laid out from the top, as SwiftUI and the stage are.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Runs `body` now, and again whenever anything it read that's observed changes (once per change, on the main
/// queue): SwiftUI's way of drawing a view again, for layers.
@MainActor
final class Watching {
    private let body: () -> Void
    private var stopped = false
    private var generation = 0

    init(_ body: @escaping () -> Void) {
        self.body = body
        run()
    }

    /// Runs it again now (what it reads may have changed in ways not watched), watching from here.
    func again() {
        generation += 1
        run()
    }

    private func run() {
        guard !stopped else { return }
        let g = generation
        withObservationTracking(body) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == g else { return }
                self.again()
            }
        }
    }

    func stop() { stopped = true }
}

// MARK: - The badges and buttons (SwiftUI)

/// A tile's badges or buttons, hosted: clicks go through it to the tile except on what it marks clickable.
final class ChromeHost: NSHostingView<AnyView> {
    var clickable: [CGRect] = []

    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard !isHidden, clickable.contains(where: { $0.contains(p) }) else { return nil }
        return super.hitTest(point)
    }
}

/// The places in a tile's hosted badges that take clicks.
struct ChromeHits: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// This takes clicks (in a tile's hosted badges), while `enabled`.
    func chromeHit(_ enabled: Bool = true) -> some View {
        background {
            GeometryReader { g in
                Color.clear.preference(key: ChromeHits.self, value: enabled ? [g.frame(in: .named(ChromeHits.space))] : [])
            }
        }
    }

    /// Tells `told` where in this view clicks are taken.
    func chromeHits(_ told: @escaping ([CGRect]) -> Void) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(ChromeHits.space))
            .onPreferenceChange(ChromeHits.self, perform: told)
    }
}

extension ChromeHits {
    static let space = "chrome"
}

/// Bottom left: the name, always; then its badges in their one order (as `CameraTile.badges`).
struct TileNameRow: View {
    @Environment(AppModel.self) private var model
    let state: StageTileState

    var body: some View {
        let compact = state.compact
        HStack(spacing: CameraTile.badgeGap) {
            Text("\(state.camera.name)\(Text(model.pondName(of: state.camera.id).map { "  \($0)" } ?? "").foregroundStyle(.secondary))")
                .font(compact ? .callout.weight(.semibold) : .headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, compact ? 10 : 13)
                .frame(height: compact ? CameraTile.compactPillHeight : CameraTile.pillHeight)
                .glassEffect(.regular, in: .capsule)
                .layoutPriority(1)
            ForEach(shownBadges) { badge in
                TileBadgeView(state: state, badge: badge)
                    .chromeHit()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shownBadges)
        // (Room left for the buttons at the right.)
        .padding(.trailing, state.trailingWidth > 0 ? state.trailingWidth + CameraTile.badgeGap : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var shownBadges: [CameraTile.TileBadge] {
        guard state.frozen == nil else { return [] }
        let camera = state.camera
        let canPrivacy = AppModel.pond(of: camera.id) == nil && !model.isPrivateOnCameraOnly(camera.id)
        let homeKit = model.homeKitState(for: camera)
        let hovering = state.hovering
        return CameraTile.TileBadge.allCases.filter { badge in
            switch badge {
            case .privacy: canPrivacy && (hovering || model.isPrivate(camera.id))
            case .gear: hovering
            case .doctor: model.doctor.mark(camera.id) != nil
            case .homeKit: homeKit.map { hovering || $0.needsAttention } ?? false
            }
        }
    }
}

/// One of the badges beside a tile's name (as `CameraTile.tileBadge`).
struct TileBadgeView: View {
    @Environment(AppModel.self) private var model
    let state: StageTileState
    let badge: CameraTile.TileBadge

    var body: some View {
        let compact = state.compact
        let camera = state.camera
        let diameter = compact ? CameraTile.compactPillHeight : CameraTile.pillHeight
        switch badge {
        case .gear:
            Button { model.editCameraSettings(camera.id) } label: {
                Image(systemName: "gearshape.fill")
                    .font(compact ? .callout : .headline)
                    .frame(width: diameter - 8, height: diameter - 8)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help("\(camera.name) settings")
        case .privacy:
            let isPrivate = model.isPrivate(camera.id)
            Button { Task { await model.setPrivacy(camera.id, !isPrivate) } } label: {
                Image(systemName: isPrivate ? "eye.slash.fill" : "eye.slash")
                    .font(compact ? .callout : .headline)
                    .foregroundStyle(isPrivate ? AnyShapeStyle(CameraHealth.keptPrivate.tint) : AnyShapeStyle(.primary))
                    .frame(width: diameter - 8, height: diameter - 8)
            }
            .buttonStyle(.glass(isPrivate ? .regular.tint(CameraHealth.keptPrivate.tint.opacity(0.25)) : .regular))
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help(isPrivate ? "Private: not recorded, shown live or in the Home app. Click to record \(camera.name) again."
                            : "Make \(camera.name) private: not recorded, shown live or in the Home app until you turn it off")
        case .doctor:
            if let finding = model.doctor.mark(camera.id) {
                Button {
                    model.showDoctor(camera: camera.id)
                } label: {
                    Image(systemName: "stethoscope")
                        .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                        .foregroundStyle(finding.severity == .problem ? .red : .orange)
                        .padding(.horizontal, compact ? 7 : 10)
                        .frame(minHeight: diameter, maxHeight: diameter)
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("\(finding.headline): \(finding.evidence). Click for the doctor.")
            }
        case .homeKit:
            if let homeKit = model.homeKitState(for: camera) {
                HomeKitBadge(camera: camera, state: homeKit, compact: compact, height: diameter,
                             popoverShown: { state.popoverOpen = $0 })
            }
        }
    }
}

/// Bottom right: sound, talking, the picture's size (as the right of `CameraTile.badges`).
struct TileTrailingRow: View {
    @Environment(AppModel.self) private var model
    let state: StageTileState

    var body: some View {
        let compact = state.compact
        let camera = state.camera
        let hovering = state.hovering
        let audible = model.audibleCamera == camera.id
        let talking = model.talking?.camera == camera.id
        HStack(spacing: CameraTile.badgeGap) {
            if state.stream?.hasAudio == true, state.frozen == nil, hovering || audible {
                let diameter = compact ? CameraTile.compactPillHeight : CameraTile.pillHeight
                Button { model.audibleCamera = audible ? nil : camera.id } label: {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(compact ? .callout : .headline)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: diameter - 8, height: diameter - 8)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .help(audible ? "Mute \(camera.name)" : "Listen to \(camera.name) (mutes the others)")
                .chromeHit()
                .transition(.opacity)
            }
            if model.controls(for: camera)?.talk != nil, state.frozen == nil, hovering || talking, !model.isAsleep(camera.id) {
                TalkButton(camera: camera, compact: compact)
                    .chromeHit()
                    .transition(.opacity)
            }
            if hovering, !compact, let size = state.stream?.size {
                Text("\(Int(size.width))×\(Int(size.height))")
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(height: CameraTile.pillHeight)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { state.trailingWidth = $0 }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Top right, hovered: its controls, watch it alone, take it off (as `CameraTile`'s).
struct TileCornerButtons: View {
    let state: StageTileState
    let actions: () -> StageTileView.Actions

    var body: some View {
        let compact = state.compact
        let hovering = state.hovering
        let many = state.canRemove
        HStack(spacing: 6) {
            if state.frozen == nil, many {
                Button { actions().openControls() } label: { symbol("slider.horizontal.3") }
                    .help("Controls for \(state.camera.name) (\u{2325}\u{2318}L)")
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .chromeHit(hovering)
            }
            Group {
                Button { actions().solo?() } label: { symbol("arrow.up.left.and.arrow.down.right") }
                    .help("Watch only this camera")
                Button { actions().remove() } label: { symbol("xmark") }
                    .help("Take off the screen")
            }
            .opacity(hovering && many ? 1 : 0)
            .allowsHitTesting(hovering && many)
            .chromeHit(hovering && many && state.frozen == nil)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(compact ? .small : .regular)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    func symbol(_ name: String) -> some View {
        let compact = state.compact
        let diameter = compact ? CameraTile.compactPillHeight : CameraTile.pillHeight
        return Image(systemName: name)
            .font(compact ? .callout : .headline)
            .frame(width: diameter - 8, height: diameter - 8)
    }
}

/// Top left: its health; its events, hovered (as `CameraTile`'s).
struct TileTopLeading: View {
    let state: StageTileState
    let open: (TimelineEvent) -> Void

    var body: some View {
        let compact = state.compact
        let hovering = state.hovering
        VStack(alignment: .leading, spacing: 6) {
            if state.frozen == nil, state.health.showsBadge {
                HealthBadge(health: state.health, compact: compact).chromeHit()
            }
            if state.frozen == nil, let events = state.events, events.eventsToday > 0 {
                EventsChip(events: events, compact: compact, open: open, popoverShown: { state.popoverOpen = $0 })
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .chromeHit(hovering)
                    .animation(.easeOut(duration: 0.15), value: hovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Centred on the tile: what's wrong (as `CameraTile.status`), one layout at every size, scaled on small tiles.
struct TileStatusMessage: View {
    @Environment(AppModel.self) private var model
    let state: StageTileState

    var body: some View {
        let compact = state.compact
        let status = state.status(model)
        ZStack {
            message(status, compact: compact)
                .id(status)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(compact ? 0.8 : 1)
        .offset(y: compact ? -10 : 0)
    }

    @ViewBuilder
    func message(_ status: TileStatus, compact: Bool) -> some View {
        let camera = state.camera
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
}

/// Just added: "Added", at the top of the tile (as `AddedGlow`'s), with the ring (the tile's layers).
struct TileAddedChip: View {
    let state: StageTileState

    var body: some View {
        let active = state.announced
        let change: Animation = active ? .spring(duration: 0.5, bounce: 0.35).delay(0.6)
            : state.superseded ? .easeOut(duration: 0.15) : .easeOut(duration: 0.6)
        Label("Added", systemImage: "plus.circle.fill")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.accentColor.opacity(0.5)), in: .capsule)
            .animation(change) { chip in
                chip.scaleEffect(active ? 1 : 0.7).opacity(active ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}
