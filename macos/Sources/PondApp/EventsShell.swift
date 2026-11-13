// The Events page's surface in AppKit: the grid, the rail, the glass at the window's edge and the detail panel,
// laid out and moved by one view, so the panel coming in, the rail going and the cards zooming to their new width
// are one move (the same curve, begun in the same moment, run by Core Animation: none waits on the main thread, and
// none can fall behind the others). What's in the rail and the panel is SwiftUI's, hosted: a change to the panel
// works out the panel, not the page.
//
// Above it, in SwiftUI still: the filters' bar and the glass under it (`EventsView`).
import AppKit
import SwiftUI

struct EventsShell: NSViewRepresentable {
    /// The grid (nil: something in its place, `placeholder`: loading, or nothing to show).
    let grid: EventGrid?
    let placeholder: AnyView?
    /// The rail, if it's shown, and what it shows (made again only when that changes).
    let rail: AnyView?
    let railKey: RailKey
    /// The panel, if an event's open, and what it shows.
    let panel: AnyView?
    let panelKey: PanelKey?
    /// The glass at the window's edge, and whether anything's under it.
    let glass: AnyView
    let glassShown: Bool
    /// Where things go: the bars' room, the rail's place, the panel's room (beside the cards, or over them).
    let barHeight: Double
    let gridLeading: Double
    let roomMade: Bool
    let panelCovers: Bool
    let cardsHidden: Bool
    let model: AppModel

    struct RailKey: Equatable {
        var hourCounts: [Date: Int]
        var days: Int
        var dimmed: Bool
        var shown: Int
    }

    struct PanelKey: Equatable {
        var event: TimelineEvent
        var camera: String
        var fresh: Bool
        var earlier: String?
        var later: String?
        var covers: Bool
    }

    func makeNSView(context: Context) -> EventsShellView { EventsShellView(model: model) }

    func updateNSView(_ view: EventsShellView, context: Context) { view.update(self) }
}

final class EventsShellView: NSView {
    let model: AppModel
    let grid: GridHostView
    private let placeholder = NSHostingView(rootView: AnyView(EmptyView()))
    private let rail = NSHostingView(rootView: AnyView(EmptyView()))
    private let glass = PassThroughHosting(rootView: AnyView(EmptyView()))
    private let panel = NSHostingView(rootView: AnyView(EmptyView()))
    private var shown: EventsShell?
    private var railKey: EventsShell.RailKey?
    private var panelKey: EventsShell.PanelKey?
    /// The panel's going (out, then let go), and the rail's.
    private var panelLeaving: UUID?
    private var railLeaving: UUID?

    static let pad = 16.0

    init(model: AppModel) {
        self.model = model
        grid = GridHostView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [placeholder, rail, panel] { view.sizingOptions = [] }
        // Bottom to top: the cards, the rail beside them, the glass at the window's edge, the panel over that.
        for view in [grid, placeholder, rail, glass, panel] as [NSView] {
            view.wantsLayer = true
            view.isHidden = true
            addSubview(view)
        }
        panel.layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        panel.layer?.filters = [blur]
        glass.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Where things go

    private func gridFrame(_ s: EventsShell) -> CGRect {
        let trailing = s.roomMade && !s.panelCovers ? EventDetail.width + 14 : 0
        let x = Self.pad + s.gridLeading
        return CGRect(x: x, y: 0, width: max(0, bounds.width - x - Self.pad - trailing), height: bounds.height)
    }

    private func railFrame(_ s: EventsShell) -> CGRect {
        CGRect(x: Self.pad, y: s.barHeight, width: ActivityRail.width, height: max(0, bounds.height - s.barHeight))
    }

    private func panelFrame(_ s: EventsShell) -> CGRect {
        let height = max(0, bounds.height - s.barHeight - 16)
        if s.panelCovers { return CGRect(x: Self.pad, y: s.barHeight, width: max(0, bounds.width - 2 * Self.pad), height: height) }
        return CGRect(x: bounds.width - Self.pad - EventDetail.width, y: s.barHeight, width: EventDetail.width, height: height)
    }

    private func glassFrame() -> CGRect {
        CGRect(x: 0, y: bounds.height - EventsView.bottomFade, width: bounds.width, height: EventsView.bottomFade)
    }

    override func layout() {
        super.layout()
        guard let s = shown else { return }
        // (Resized: everything where it goes, at once.)
        place(s)
        if let config = s.grid { grid.update(config) }
    }

    private func place(_ s: EventsShell) {
        let g = gridFrame(s)
        if grid.frame != g { grid.frame = g }
        placeholder.frame = g
        rail.frame = railFrame(s)
        panel.frame = panelFrame(s)
        glass.frame = glassFrame()
    }

    // MARK: Told what to show

    func update(_ s: EventsShell) {
        let old = shown
        shown = s
        // The pieces' own: what they show, made again only when that's changed.
        if let content = s.rail, s.railKey != railKey {
            railKey = s.railKey
            rail.rootView = AnyView(content.environment(model))
        }
        if let content = s.panel, s.panelKey != panelKey {
            panelKey = s.panelKey
            panel.rootView = AnyView(content.environment(model))
        }
        if let placeholderView = s.placeholder { placeholder.rootView = AnyView(placeholderView.environment(model)) }
        glass.rootView = s.glass
        // Where they go now (the cards' room given at once: the grid moves them there itself).
        place(s)
        placeholder.isHidden = s.placeholder == nil
        grid.isHidden = s.grid == nil
        // All the moves of this change begin together, on the panel's curve.
        CATransaction.begin()
        if let config = s.grid {
            grid.layoutSubtreeIfNeeded()
            grid.update(config)
        }
        let first = old == nil
        // The cards: faded away under the panel when it covers them (a narrow window).
        if first || old?.cardsHidden != s.cardsHidden {
            fade(grid, to: s.cardsHidden ? 0 : 1, animated: !first)
            fade(placeholder, to: s.cardsHidden ? 0 : 1, animated: !first)
        }
        // The rail: sliding off its side as the cards take its room, and back as they make it.
        let railShown = s.rail != nil
        if first || (old?.rail != nil) != railShown { slideRail(in: railShown, animated: !first) }
        // The panel: in from the side (or up from the bottom, over the cards), out the same way.
        let panelShown = s.panel != nil
        if first || (old?.panel != nil) != panelShown { slidePanel(in: panelShown, covers: s.panelCovers, animated: !first) }
        // The glass at the window's edge, while anything's under it.
        let glassAlpha: Float = s.glassShown && !s.cardsHidden ? 1 : 0
        if let layer = glass.layer, layer.opacity != glassAlpha {
            GridCardView.change(layer, "opacity", to: glassAlpha, animated: !first, duration: 0.2)
        }
        CATransaction.commit()
    }

    // MARK: The moves

    /// The panel's curve (`EventGrid.reshapeAnimation`), which the grid's zoom runs on too.
    private func spring(_ key: String, from: Any?, to: Any?) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: 0.4, bounce: 0)
        a.keyPath = key
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    private func set(_ layer: CALayer, _ key: String, _ value: Any?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
    }

    private func fade(_ view: NSView, to alpha: Float, animated: Bool) {
        guard let layer = view.layer else { return }
        if animated { layer.add(spring("opacity", from: layer.presentation()?.opacity ?? layer.opacity, to: alpha), forKey: "fade") }
        set(layer, "opacity", alpha)
    }

    private func slideRail(in coming: Bool, animated: Bool) {
        guard let layer = rail.layer else { return }
        // (Off its leading side, as SwiftUI's `.move(edge: .leading)` takes it, fading.)
        let away = GridHostView.moving(layer, from: rail.frame, to: rail.frame.offsetBy(dx: -rail.frame.width, dy: 0), scale: 1)
        let id = UUID()
        railLeaving = coming ? nil : id
        // (From where it's drawn, mid-move; else from where it's coming from: hidden, it's drawn nowhere.)
        let moving = layer.animation(forKey: "slide") != nil ? layer.presentation() : nil
        if coming { rail.isHidden = false }
        if animated {
            layer.add(spring("transform", from: moving?.transform ?? (coming ? away : CATransform3DIdentity),
                             to: coming ? CATransform3DIdentity : away), forKey: "slide")
            layer.add(spring("opacity", from: moving?.opacity ?? (coming ? 0 : 1), to: coming ? 1 : 0), forKey: "slide.fade")
        }
        set(layer, "transform", coming ? CATransform3DIdentity : away)
        set(layer, "opacity", Float(coming ? 1 : 0))
        if !coming {
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? spring("", from: nil, to: nil).duration : 0)) { [weak self] in
                guard let self, self.railLeaving == id else { return }
                self.rail.isHidden = true
                self.railKey = nil
            }
        }
    }

    private func slidePanel(in coming: Bool, covers: Bool, animated: Bool) {
        guard let layer = panel.layer else { return }
        // Beside the cards: off the window's side (its width, and the gap); over them: down off its bottom, out of
        // focus (`PanelComing`).
        let off = covers ? panel.frame.offsetBy(dx: 0, dy: panel.frame.height) : panel.frame.offsetBy(dx: panel.frame.width + 16, dy: 0)
        let away = GridHostView.moving(layer, from: panel.frame, to: off, scale: 1)
        let blur = covers ? 24.0 : 0
        let id = UUID()
        panelLeaving = coming ? nil : id
        let moving = layer.animation(forKey: "slide") != nil ? layer.presentation() : nil
        if coming { panel.isHidden = false }
        if animated {
            layer.add(spring("transform", from: moving?.transform ?? (coming ? away : CATransform3DIdentity),
                             to: coming ? CATransform3DIdentity : away), forKey: "slide")
            layer.add(spring("opacity", from: moving?.opacity ?? (coming ? 0 : 1), to: coming ? 1 : 0), forKey: "slide.fade")
            layer.add(spring("filters.blur.inputRadius", from: coming ? blur : 0, to: coming ? 0 : blur), forKey: "slide.blur")
        }
        set(layer, "transform", coming ? CATransform3DIdentity : away)
        set(layer, "opacity", Float(coming ? 1 : 0))
        set(layer, "filters.blur.inputRadius", coming ? 0 : blur)
        if !coming {
            DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? spring("", from: nil, to: nil).duration : 0)) { [weak self] in
                guard let self, self.panelLeaving == id else { return }
                self.panel.isHidden = true
                // (What it showed let go, once it's gone.)
                self.panel.rootView = AnyView(EmptyView())
                self.panelKey = nil
            }
        }
    }
}
