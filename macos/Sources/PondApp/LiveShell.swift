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
    /// The dock and the button that shows and hides it, one piece (a camera watched on its own), open or not; over
    /// the stage (hidden, only its button showing; or reaching up over it, a camera's other positions open).
    let dock: AnyView?
    let dockOpen: Bool
    let dockOver: Bool
    /// The adjustments down the right, when they're there.
    let sidebar: AnyView?
    let model: AppModel

    func makeNSView(context: Context) -> LiveShellView { LiveShellView(model: model) }

    func updateNSView(_ view: LiveShellView, context: Context) {
        let t = context.transaction
        view.update(self, animated: t.animation != nil && !t.disablesAnimations, panelsAtOnce: model.railMovesAtOnce)
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
    /// The dock's piece: the column's width, from far above the button (room for what reaches up over the stage)
    /// to the dock's bottom; clicks taken only on what's in it.
    private let dock = ChromeHost()
    private var shell: LiveShell?
    /// What's laid out: each panel there or not.
    private var shown = Shown()
    /// Panels on their way out: let go once gone (a newer change keeps them).
    private var going: [ObjectIdentifier: UUID] = [:]

    struct Shown: Equatable {
        var rail = false, dock = false, dockOpen = false, sidebar = false
    }

    /// The side panels' curve (`LiveView.dockAnimation`).
    static let curve = LiveStageView.reflowCurve
    /// The rail's resize handle sits past its edge, in the gap before the stage.
    static let handleOverhang: CGFloat = 10

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
        dock.isHidden = true
        addSubview(dock)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func tearDown() { stage.tearDown() }

    // MARK: Told what to show

    func update(_ s: LiveShell, animated: Bool, panelsAtOnce: Bool) {
        shell = s
        rail.rootView = AnyView(s.rail.environment(model))
        if let content = s.dock {
            dock.rootView = AnyView(content.padding(.top, max(bounds.height, 1)).frame(maxHeight: .infinity, alignment: .top)
                .chromeHits { [weak dock] in dock?.clickable = $0 }.environment(model))
        }
        if let content = s.sidebar { sidebar.rootView = AnyView(content.environment(model)) }
        arrange(animated: animated && !panelsAtOnce)
        stage.update(s.stage, animated: animated)
    }

    override func layout() {
        super.layout()
        arrange(animated: false)
    }

    // MARK: Where the panels go

    private struct Frames {
        var rail: CGRect, stage: CGRect, dock: CGRect, sidebar: CGRect
    }

    private func frames(_ s: LiveShell, _ shown: Shown, in size: CGSize) -> Frames {
        let railRoom = LiveLayout.railRoom(Double(s.railWidth))
        let railHost = railRoom + Self.handleOverhang
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
        return Frames(rail: CGRect(x: shown.rail ? 0 : -railHost, y: 0, width: railHost, height: size.height),
                      stage: stage,
                      dock: CGRect(x: left, y: top - above, width: width, height: above + piece),
                      sidebar: CGRect(x: shown.sidebar ? size.width - LiveLayout.sidebarRoom : size.width, y: 0,
                                      width: LiveLayout.sidebarRoom, height: size.height))
    }

    /// Each panel to its place: moving there on the panels' curve, or at once (the window resized, the first time).
    private func arrange(animated: Bool) {
        guard let s = shell, bounds.size != .zero else { return }
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
        place(sidebar, target.sidebar, curve: curve)
        show(sidebar, now.sidebar, was: was.sidebar, curve: curve)
        place(dock, target.dock, curve: curve, centred: true)
        show(dock, now.dock, was: was.dock, curve: curve)
        if stage.frame != target.stage {
            if let curve, stage.frame.size != target.stage.size { stage.resizeCurve = curve }
            place(stage, target.stage, curve: curve)
        }
        // Open, the stage is over the dock (tiles growing back over its place pass over it); hidden, or reaching up
        // over the stage, the dock is over it. (Its clicks are taken only where it has something, either way.)
        stage.layer?.zPosition = s.dockOver ? 0 : 1
        dock.layer?.zPosition = s.dockOver ? 2 : 0
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
