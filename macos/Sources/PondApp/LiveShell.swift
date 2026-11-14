// Live's view in AppKit: the cameras' rail down the left, the stage, the dock under it, the adjustments' sidebar down
// the right. Each panel is SwiftUI, hosted once and laid out at its size; it moves (comes, goes, makes room) by Core
// Animation, on one clock with the stage's tiles: SwiftUI animating them moved its layout frame by frame, the rail
// and the stage laid out again for every frame of the rail's slide (docs/live-stage.md).
import AppKit
import SwiftUI

struct LiveShell: NSViewRepresentable {
    /// The cameras' rail, shown or not, and its own width (as kept and dragged).
    let rail: AnyView
    let railShown: Bool
    let railWidth: CGFloat
    let stage: LiveStageShell
    /// The button that shows and hides the dock, and the dock (a camera watched on its own), open or not; over
    /// the stage (hidden, only its button showing; or reaching up over it, a camera's other positions open).
    let dockButton: AnyView?
    let dock: AnyView?
    let dockOpen: Bool
    let dockOver: Bool
    /// The adjustments down the right, when they're there.
    let sidebar: AnyView?
    let model: AppModel

    func makeNSView(context: Context) -> LiveShellView { LiveShellView(model: model) }

    func updateNSView(_ view: LiveShellView, context: Context) {
        let t = context.transaction
        // (The panels move on their own curve whether or not the change came animated; at once only when asked, or as
        // the window's resized.)
        view.update(self, animated: t.animation != nil && !t.disablesAnimations, panelsAnimated: !t.disablesAnimations,
                    panelsAtOnce: model.railMovesAtOnce)
    }

    static func dismantleNSView(_ view: LiveShellView, coordinator: ()) { view.tearDown() }
}

/// A panel's SwiftUI, laid out at the size it's given (not its own).
final class PanelHost: NSHostingView<AnyView> {
    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }
}

final class LiveShellView: NSView {
    let model: AppModel
    private let stage: LiveStageView
    private let rail = PanelHost()
    private let sidebar = PanelHost()
    /// The button that shows and hides the dock; and the dock, the column's width, from far above it (room for what
    /// reaches up over the stage) to its bottom, faded here as it comes and goes (faded in its own SwiftUI, it vanished
    /// at once, closing). Clicks taken only on what's in them.
    private let button = ChromeHost()
    private let dock = ChromeHost()
    private var shell: LiveShell?
    /// What's laid out: each panel there or not.
    private var shown = Shown()
    /// Panels on their way out: let go once gone (a newer change keeps them).
    private var going: [ObjectIdentifier: UUID] = [:]
    /// The rail's resize handle, in the gap before the stage, over it: dragged, the rail and the stage are resized here,
    /// together, in the same event (resized by the rail's own SwiftUI, through its kept width, the stage followed a
    /// step behind the mouse and the rail spilled under the tiles; and the stage over the handle took most of its clicks).
    private let handle = RailHandle()
    /// The rail's width while it's dragged (kept once let go, till the kept width says the same).
    private var draggedWidth: CGFloat?
    private var dragFrom: CGFloat = 0
    /// When the view was first laid out at a size: for a moment after, everything is drawn at once (`quiet`).
    private var opened: Date?
    /// How long after opening changes aren't animated: the cameras, the lineup and the panels arriving.
    static let openingQuiet: TimeInterval = 2
    private var quiet: Bool { opened.map { Date().timeIntervalSince($0) < Self.openingQuiet } ?? true }

    struct Shown: Equatable {
        var rail = false, dock = false, dockOpen = false, sidebar = false
    }

    /// The side panels' curve (`LiveView.dockAnimation`).
    static let curve = LiveStageView.reflowCurve
    /// The handle's width, centred just past the rail's room (in the gap before the stage).
    static let handleWidth: CGFloat = 16

    init(model: AppModel) {
        self.model = model
        stage = LiveStageView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        for host in [rail, sidebar] as [NSView] {
            host.isHidden = true
            addSubview(host)
        }
        addSubview(stage)
        for host in [dock, button] as [NSView] {
            host.isHidden = true
            addSubview(host)
        }
        handle.isHidden = true
        addSubview(handle)
        handle.began = { [weak self] in
            guard let self, let s = self.shell else { return }
            self.dragFrom = self.draggedWidth ?? s.railWidth
        }
        handle.moved = { [weak self] dx in
            guard let self else { return }
            // No wider than leaves the open controls room.
            let widest = max(CameraRail.widths.lowerBound, min(CameraRail.widths.upperBound, self.model.railLimit ?? .infinity))
            self.draggedWidth = (self.dragFrom + dx).clamped(to: CameraRail.widths.lowerBound ... widest)
            self.arrange(animated: false)
        }
        handle.ended = { [weak self] in
            guard let self, let width = self.draggedWidth else { return }
            AppDefaults.store.set(Double(width), forKey: LiveView.railWidthKey)
        }
        handle.reset = { [weak self] in
            guard let self else { return }
            self.draggedWidth = nil
            AppDefaults.store.set(CameraRail.defaultWidth, forKey: LiveView.railWidthKey)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func tearDown() { stage.tearDown() }

    // MARK: Told what to show

    func update(_ s: LiveShell, animated: Bool, panelsAnimated: Bool, panelsAtOnce: Bool) {
        shell = s
        // The kept width caught up with the one dragged: it's the kept one again.
        if let dragged = draggedWidth, !handle.dragging, abs(dragged - s.railWidth) < 0.5 { draggedWidth = nil }
        rail.rootView = AnyView(s.rail.environment(model))
        if let content = s.dockButton {
            button.rootView = AnyView(content.chromeHits { [weak button] in button?.clickable = $0 }.environment(model))
        }
        if let content = s.dock {
            dock.rootView = AnyView(content.padding(.top, max(bounds.height, 1)).frame(maxHeight: .infinity, alignment: .top)
                .chromeHits { [weak dock] in dock?.clickable = $0 }.environment(model))
        }
        if let content = s.sidebar { sidebar.rootView = AnyView(content.environment(model)) }
        arrange(animated: panelsAnimated && !panelsAtOnce && !(window?.inLiveResize ?? false))
        stage.quiet = quiet
        stage.update(s.stage, animated: animated)
    }

    override func layout() {
        super.layout()
        arrange(animated: false)
    }

    // MARK: Where the panels go

    private struct Frames {
        var rail: CGRect, handle: CGRect, stage: CGRect, button: CGRect, dock: CGRect, sidebar: CGRect
    }

    private func frames(_ s: LiveShell, _ shown: Shown, in size: CGSize) -> Frames {
        let railRoom = LiveLayout.railRoom(Double(draggedWidth ?? s.railWidth))
        let left = shown.rail ? railRoom : 0
        let right = shown.sidebar ? LiveLayout.sidebarRoom : 0
        let width = max(0, size.width - left - right)
        let dockRoom = shown.dock && shown.dockOpen ? LiveView.dockToggleRoom + 12 + LiveControlsDock.height() : 0
        let stage = CGRect(x: left, y: 0, width: width, height: max(0, size.height - dockRoom))
        // The piece's top: on the dock's room's top edge, open; hidden, only the button up over the stage's bottom.
        let top = stage.maxY + (shown.dockOpen ? LiveView.dockToggleRoom - LiveView.controlsButtonHeight - 8
                                               : -(LiveView.controlsButtonHeight + 14))
        let piece = LiveView.controlsButtonHeight + 8 + LiveControlsDock.height()
        let above = max(size.height, 1)
        let inset = LiveLayout.railLeading
        return Frames(rail: CGRect(x: shown.rail ? 0 : -railRoom, y: 0, width: railRoom, height: size.height),
                      handle: CGRect(x: (shown.rail ? railRoom : 0) + 2 - Self.handleWidth / 2, y: inset, width: Self.handleWidth,
                                     height: max(0, size.height - 2 * inset)),
                      stage: stage,
                      button: CGRect(x: left, y: top, width: width, height: LiveView.controlsButtonHeight),
                      dock: CGRect(x: left, y: top + LiveView.controlsButtonHeight + 8 - above, width: width,
                                   height: above + piece - LiveView.controlsButtonHeight - 8),
                      sidebar: CGRect(x: shown.sidebar ? size.width - LiveLayout.sidebarRoom : size.width, y: 0,
                                      width: LiveLayout.sidebarRoom, height: size.height))
    }

    /// Each panel to its place: moving there on the panels' curve, or at once (the window resized, the first time).
    private func arrange(animated: Bool) {
        guard let s = shell, bounds.size != .zero else { return }
        if opened == nil { opened = Date() }
        stage.quiet = quiet
        let animated = animated && !quiet
        let was = shown
        let now = Shown(rail: s.railShown, dock: s.dock != nil, dockOpen: s.dockOpen, sidebar: s.sidebar != nil)
        shown = now
        let target = frames(s, now, in: bounds.size)
        let animate = animated && stage.frame.size != .zero
        let curve = animate ? Self.curve : nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(rail, target.rail, curve: curve)
        show(rail, now.rail, was: was.rail, curve: curve)
        place(handle, target.handle, curve: curve)
        show(handle, now.rail, was: was.rail, curve: curve)
        handle.layer?.zPosition = 3
        place(sidebar, target.sidebar, curve: curve)
        show(sidebar, now.sidebar, was: was.sidebar, curve: curve)
        place(button, target.button, curve: curve, centred: true)
        show(button, now.dock, was: was.dock, curve: curve)
        place(dock, target.dock, curve: curve, centred: true)
        show(dock, now.dock && now.dockOpen, was: was.dock && was.dockOpen, curve: curve)
        if stage.frame != target.stage {
            if let curve, stage.frame.size != target.stage.size { stage.resizeCurve = curve }
            place(stage, target.stage, curve: curve)
        }
        // Open, the stage is over the dock (tiles growing back over its place pass over it); hidden, or reaching up
        // over the stage, the dock is over it. (Its clicks are taken only where it has something, either way.)
        stage.layer?.zPosition = s.dockOver ? 0 : 1
        dock.layer?.zPosition = s.dockOver ? 2 : 0
        button.layer?.zPosition = s.dockOver ? 2 : 0
        CATransaction.commit()
    }

    /// A view to `frame`, from where it's drawn: its top left carried along on `curve` (what's in it, laid out at its
    /// new size, moves with it as one); `centred`, its middle across (what's in it is centred: the dock, its column
    /// narrowed by the sidebar coming, moves over by half as much, not its left edge's nothing).
    private func place(_ view: NSView, _ frame: CGRect, curve: StageCurve?, centred: Bool = false) {
        let old = view.frame
        guard old != frame else { return }
        view.frame = frame
        guard let curve, old.size != .zero, let layer = view.layer else { return }
        let flipped = layer.superlayer?.contentsAreFlipped() ?? true
        let across = centred ? old.midX - frame.midX : old.minX - frame.minX
        let shift = CGSize(width: across, height: flipped ? old.minY - frame.minY : frame.minY - old.minY)
        guard shift != .zero else { return }
        layer.add(curve.animation("transform.translation", from: NSValue(size: shift), to: NSValue(size: .zero), on: layer,
                                  additive: true), forKey: "move.\(UUID().uuidString)")
    }

    /// A panel coming (fading in as it moves) or going (fading out, then hidden).
    private func show(_ view: NSView, _ shown: Bool, was: Bool, curve: StageCurve?) {
        let key = ObjectIdentifier(view)
        guard let layer = view.layer else {
            view.isHidden = !shown
            return
        }
        if shown {
            going[key] = nil
            view.isHidden = false
            let from = layer.presentation()?.opacity ?? (was ? 1 : 0)
            layer.opacity = 1
            if let curve, !was || from < 1 {
                layer.add(curve.animation("opacity", from: was ? from : 0, to: 1, on: layer), forKey: "fade")
            }
        } else if was || !view.isHidden {
            let from = layer.presentation()?.opacity ?? 1
            layer.opacity = 0
            guard let curve else {
                view.isHidden = true
                return
            }
            layer.add(curve.animation("opacity", from: from, to: 0, on: layer), forKey: "fade")
            let id = UUID()
            going[key] = id
            DispatchQueue.main.asyncAfter(deadline: .now() + min(curve.length, 0.6)) { [weak self, weak view] in
                guard let self, let view, self.going[key] == id else { return }
                self.going[key] = nil
                view.isHidden = true
            }
        }
    }
}

/// The rail's resize handle: a grip that brightens and grows under the pointer; dragged, it says how far (in the
/// window, so one to one with the mouse); double-clicked, back to the usual width.
final class RailHandle: NSView {
    var began: () -> Void = {}
    var moved: (CGFloat) -> Void = { _ in }
    var ended: () -> Void = {}
    var reset: () -> Void = {}
    private(set) var dragging = false
    private var from: CGFloat?
    private var hovering = false
    private let grip = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        grip.cornerRadius = 2.5
        grip.cornerCurve = .continuous
        layer?.addSublayer(grip)
        toolTip = "Drag to resize the list of cameras; double-click for the usual width"
        restyle(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func layout() {
        super.layout()
        restyle(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle(animated: true) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            reset()
            return
        }
        from = event.locationInWindow.x
        dragging = true
        restyle(animated: true)
        began()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from else { return }
        moved(event.locationInWindow.x - from)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        from = nil
        restyle(animated: true)
        ended()
    }

    /// Its grip: 5 pt wide, 40 tall (54 under the pointer or dragged), the secondary colour faint (brighter then).
    private func restyle(animated: Bool) {
        let lit = hovering || dragging
        let height: CGFloat = lit ? 54 : 40
        var colour = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { colour = NSColor.secondaryLabelColor.withAlphaComponent(lit ? 0.8 : 0.4) }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        grip.frame = CGRect(x: (bounds.width - 5) / 2, y: (bounds.height - height) / 2, width: 5, height: height)
        grip.backgroundColor = colour.cgColor
        CATransaction.commit()
    }
}
