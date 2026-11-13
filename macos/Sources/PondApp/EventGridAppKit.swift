// The Events grid in AppKit: the same grid as `EventGrid` (its layout, its rules for what moves when, in
// `GridMotion`; its inputs, an `EventGrid` value's), drawn with an NSScrollView and layer-backed cards
// (`GridCardView`) reused as they scroll off and on. In SwiftUI, a change anywhere on the Events page had SwiftUI
// go through every card's views again; here a card is a few layers, changed only when what it shows changes.
//
// Behind a hidden setting while it's made: `defaults write camera.pond eventsAppKitGrid -bool true` (the demo's:
// camera.pond.demo). The day headers, the Now button and the order's switch are SwiftUI's (a few, hosted), so they
// look as they do in `EventGrid`.
import AppKit
import SwiftUI

struct EventGridAppKit: NSViewRepresentable {
    /// What to show, and what to do: as for the SwiftUI grid.
    let grid: EventGrid
    let model: AppModel
    func makeNSView(context: Context) -> GridHostView { GridHostView(model: model) }

    func updateNSView(_ view: GridHostView, context: Context) { view.update(grid) }
}

/// The grid: a scroll view of cards, the pinned day and the order's switch over it.
@MainActor
final class GridHostView: NSView {
    let model: AppModel
    let scroll = NSScrollView()
    let document = GridDocumentView()
    private(set) var config: EventGrid?
    private let cache = LayoutCache()
    private(set) var laidOut: EventGridLayout?
    var motion = GridMotion()

    fileprivate var cards: [String: GridCardView] = [:]
    fileprivate var spare: [GridCardView] = []
    fileprivate var headers: [Date: PassThroughHosting<GridDayHeader>] = [:]
    fileprivate let pinned = PassThroughHosting(rootView: GridDayHeader.empty)
    fileprivate let order = PassThroughHosting(rootView: AnyView(EmptyView()))
    /// The panel's zoom under way (see `zoom(from:)`).
    fileprivate var zooming: Zooming?
    /// Through the zoom, from the document's terms to the grid's (the stages and headers are over the scroll view).
    fileprivate var zoomShift: CGPoint?

    /// The day's capsule's height (the order's switch as tall).
    private var dayCapsule = 40.0

    private var told: Set<String> = []
    private var toldTop = true, toldNear = true, toldScrolled = false, toldUnder = false
    private var hovered: String?
    /// A scroll to a card or the top, under way.
    fileprivate var gliding: (from: Double, to: Double, began: CFTimeInterval, link: CADisplayLink)?
    /// Waiting on a far jump's pictures, past a moment.
    fileprivate let spinner = NSProgressIndicator()
    /// Scrolling fast (`EventGrid.track`): how fast, the cards plain blocks, dimmed, the day and hour over them.
    fileprivate var speed: (last: (y: Double, t: Double)?, value: Double, fast: Int, beat: Int) = (nil, 0, 0, 0)
    fileprivate var steeredUntil = 0.0
    fileprivate var scrubbing = false
    fileprivate var settleToken: UUID?
    fileprivate let scrubLabel = PassThroughHosting(rootView: AnyView(EmptyView()))
    private var performed: UUID?
    private var resizeStep: UUID?
    /// Set by the Events shell before an update that's the window's size class changing (not the panel opening or
    /// closing, though the grid's told the panel's open or not: over the cards, it isn't).
    var sizeClassChanged = false

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        document.host = self
        addSubview(scroll)
        addSubview(pinned)
        addSubview(order)
        // (Faded and blurred through a far jump or a swap: the scroll view's clip view, what's on screen, and the
        // pinned day over it.)
        for view in [scroll.contentView, pinned] as [NSView] {
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            view.layer?.filters = [blur]
        }
        addSubview(scrubLabel)
        scrubLabel.alphaValue = 0
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolledByHand), name: NSScrollView.willStartLiveScrollNotification,
                                               object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Where things are

    var topInset: Double { config?.topInset ?? 0 }
    var bottomInset: Double { config?.bottomInset ?? 0 }
    /// How far down the cards are scrolled (from their top, as the layout counts).
    var offset: Double { scroll.contentView.bounds.minY }
    /// The height between the room above and below, where cards are in view.
    var viewHeight: Double { max(0, scroll.contentView.bounds.height - topInset - bottomInset) }
    var margin: Double { max(600, viewHeight * 1.5) }

    /// Room for a scroller that takes it (scroll bars always shown), and a little either side of it.
    var gutter: Double {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 2 * EventGrid.scrollerGap : 0
    }

    // MARK: Told what to show

    /// Told what to show. In the Events shell (`EventsShell`), its frame's set first, so a change of the panel finds
    /// it at its new size, and its zoom begins in the same moment as the panel's and the rail's moves.
    func update(_ grid: EventGrid) {
        let old = config
        config = grid
        let before = laidOut
        // A far jump under way: events come meanwhile wait till it's settled (a swap's own, though, it lands).
        if let old, old.sections != grid.sections, motion.holdsEvents { motion.hold(old.sections) }
        let now = cache.layout(sections: drawnSections, width: grid.width - gutter, columns: grid.columns)
        laidOut = now
        // (Its scroller where SwiftUI's scroll view has it: in from the edge a little; measured, side by side.)
        scroll.scrollerInsets = NSEdgeInsets(top: grid.topInset, left: 0, bottom: grid.bottomInset, right: 5)
        sizeDocument()
        if old == nil { motion.measured(panelOpen: grid.panelOpen, leading: grid.leading) }
        let railChanged = old.map { $0.leading != grid.leading && $0.panelOpen == grid.panelOpen } ?? false
        if railChanged { _ = motion.panelChanged(open: grid.panelOpen, leading: grid.leading) }
        // The window's size, not the panel: being resized (dragged), or into another size class (the panel over the
        // cards now, or beside them; the rail come or gone). The top card's kept where it is, no centring, no jump
        // (taken for the panel closing, going narrow had the grid scroll a long way to the card); the cards follow
        // the window (a zoom, begun under it, went stale as it kept changing), the grid sliding beside the rail as it
        // goes or comes (`EventsShell`).
        let byWindow = window?.inLiveResize == true || sizeClassChanged
        sizeClassChanged = false
        if let old, let before, viewHeight > 0, byWindow, old.panelOpen != grid.panelOpen || railChanged {
            if old.panelOpen != grid.panelOpen { _ = motion.panelChanged(open: grid.panelOpen, leading: grid.leading) }
            scroll.frame = bounds
            sizeDocument()
            land(at: anchored(from: before))
        } else if let old, let before, viewHeight > 0 {
            if old.panelOpen != grid.panelOpen {
                scroll.frame = bounds
                sizeDocument()
                panelChanged(from: before)
            } else if railChanged {
                // The rail come or gone with the window's size (the panel open, it's the rail or the panel): the cards
                // zoom to their new room, as when the panel opens, the rail sliding beside them. (Moved there at once,
                // the rail slid in over the cards.)
                scroll.frame = bounds
                sizeDocument()
                zoom(from: before, to: anchored(from: before), shiftX: old.leading - grid.leading)
            } else if old.sections != grid.sections, motion.waiting == nil {
                eventsChanged(from: before)
            } else if old.width != grid.width || old.columns != grid.columns {
                resized(from: before)
            }
        }
        refresh()
        // The bars' room above the cards changed (a row under the filters come or gone, a search's): the cards, the
        // pinned day and the switch eased there, as the bar's row is (`EventsView.barHeight`), not put there at once.
        if let old, old.topInset != grid.topInset, viewHeight > 0 {
            let dy = old.topInset - grid.topInset
            for view in [document, pinned, order] as [NSView] {
                guard let layer = view.layer else { continue }
                let a = CASpringAnimation(perceptualDuration: 0.35, bounce: 0)
                a.keyPath = "transform"
                a.fromValue = Self.moving(layer, from: view.frame, to: view.frame.offsetBy(dx: 0, dy: dy), scale: 1)
                a.toValue = CATransform3DIdentity
                a.isAdditive = true
                a.duration = a.settlingDuration
                layer.add(a, forKey: "inset")
            }
        }
        if let request = grid.request, request.id != performed {
            performed = request.id
            // (After this update: it changes the Events view's state.)
            DispatchQueue.main.async { [self] in
                config?.$request.wrappedValue = nil
                perform(request)
            }
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        sizeDocument()
        refresh()
    }

    private func sizeDocument() {
        guard let laidOut else { return }
        let clip = scroll.contentView.bounds
        let height = max(topInset + laidOut.height + bottomInset, clip.height)
        let size = NSSize(width: clip.width, height: height)
        if document.frame.size != size { document.setFrameSize(size) }
    }

    @objc private func scrolled() {
        refresh()
        track()
    }

    /// Cards made for what's near the screen (those gone from it let go), each shown as it is; the headers, the
    /// pinned day and the switch placed; and the Events view told what's on screen.
    func refresh() {
        guard let laidOut, let config, viewHeight > 0 else { return }
        let range = (offset - margin) ... (offset + viewHeight + margin)
        let wanted = laidOut.cards(in: range)
        let ids = Set(wanted.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.isHidden = true
            spare.append(card)
            cards[id] = nil
        }
        for item in wanted {
            guard let event = config.events[item.id] else { continue }
            let card = cards[item.id] ?? made()
            cards[item.id] = card
            // (In the document; or, mid-zoom, in the zoom's stage it's been moved to: placed in the stage's own terms.)
            var frame = item.frame.offsetBy(dx: 0, dy: topInset)
            if let stage = card.superview as? GridStage { frame = frame.offsetBy(dx: -stage.docOrigin.x, dy: -stage.docOrigin.y) }
            if card.frame != frame { card.frame = frame }
            card.isHidden = false
            card.show(face(event, item.frame), animated: true)
            if card.blocked != scrubbing { card.setBlocked(scrubbing, animated: false) }
        }
        placeHeaders(laidOut)
        placePinned(laidOut)
        placeOrder(laidOut)
        tell()
    }

    private func face(_ event: TimelineEvent, _ frame: CGRect) -> GridCardView.Face {
        guard let config else { fatalError() }
        return GridCardView.Face(event: event, camera: config.name(event.camera), dated: config.byBestMatch,
                                 isNew: config.unseen.contains(event.id), fresh: config.fresh.contains(event.id),
                                 selected: config.selected == event.id,
                                 outlined: event.id == (config.selected ?? config.focus),
                                 width: frame.width, height: frame.height)
    }

    private func made() -> GridCardView {
        if let card = spare.popLast() {
            // (Still, and whole: as a card that shrank away, or was mid-move, it was left.)
            card.layer?.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.layer?.transform = CATransform3DIdentity
            card.layer?.opacity = 1
            card.layer?.filters = nil
            card.layer?.zPosition = 0
            card.layer?.shadowOpacity = 0
            CATransaction.commit()
            return card
        }
        let card = GridCardView()
        card.fetch = { [weak self] event in
            guard let self else { return false }
            return await AppModel.fetchPicture(event, client: self.model.controlClient)
        }
        document.addSubview(card)
        return card
    }

    /// The days' headers near the screen, in the grid (the pinned one hidden: it's drawn over the grid).
    private func placeHeaders(_ layout: EventGridLayout) {
        guard let config else { return }
        let pinnedIndex = layout.headers.lastIndex { $0.y <= offset + 0.5 }
        var shown: Set<Date> = []
        for (i, h) in layout.headers.enumerated() {
            guard h.y + EventGridLayout.headerHeight >= offset - margin, h.y <= offset + viewHeight + margin else { continue }
            shown.insert(h.day)
            let view = GridDayHeader(title: config.title(h.day), count: h.count)
            let host = headers[h.day] ?? {
                let host = PassThroughHosting(rootView: view)
                document.addSubview(host)
                headers[h.day] = host
                return host
            }()
            if host.rootView != view { host.rootView = view }
            var frame = CGRect(x: 0, y: topInset + h.y, width: layout.width, height: EventGridLayout.headerHeight)
            // (Over the scroll view through the zoom: in the grid's terms.)
            if host.superview is ZoomClip, let shift = zoomShift { frame = frame.offsetBy(dx: shift.x, dy: shift.y) }
            host.frame = frame
            host.isHidden = i == pinnedIndex && offset > h.y + 0.5
        }
        for (day, host) in headers where !shown.contains(day) {
            host.removeFromSuperview()
            headers[day] = nil
        }
    }

    /// The day at the top, over the grid, pushed up by the next as it arrives; the way back up beside it.
    private func placePinned(_ layout: EventGridLayout) {
        guard let config, let i = layout.headers.lastIndex(where: { $0.y <= offset + 0.5 }), offset > layout.headers[i].y + 0.5 else {
            pinned.isHidden = true
            return
        }
        let h = layout.headers[i]
        let next = i + 1 < layout.headers.count ? layout.headers[i + 1].y : .infinity
        let view = GridDayHeader(title: config.title(h.day), count: h.count, now: offset > 120, newWaiting: config.newWaiting,
                                 byBestMatch: config.byBestMatch, back: { [weak self] in self?.backUp() },
                                 capsule: { [weak self] height in self?.measured(capsule: height) },
                                 row: { [weak self] rect in self?.pinned.clickable = rect })
        if pinned.rootView != view { pinned.rootView = view }
        pinned.frame = CGRect(x: 0, y: topInset + min(0, next - offset - EventGridLayout.headerHeight),
                              width: layout.width, height: EventGridLayout.headerHeight)
        pinned.isHidden = false
    }

    private func measured(capsule height: Double) {
        guard abs(height - dayCapsule) > 0.5 else { return }
        dayCapsule = height
        DispatchQueue.main.async { [self] in if let laidOut { placeOrder(laidOut) } }
    }

    /// A search's order, and the switch between them: at the grid's top right, level with the day's header.
    private func placeOrder(_ layout: EventGridLayout) {
        guard let config, let o = config.order else {
            order.isHidden = true
            return
        }
        order.rootView = AnyView(
            OrderSwitch(bestMatch: o.bestMatch, canRank: o.canRank, compact: layout.width < 640, height: dayCapsule, choose: o.choose)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("order")) } action: { [weak self] in self?.order.clickable = $0 }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .coordinateSpace(.named("order")))
        order.frame = CGRect(x: 0, y: topInset + max(0, -offset), width: layout.width, height: EventGridLayout.headerHeight)
        order.isHidden = false
    }

    // MARK: Telling the Events view

    private func tell() {
        guard let laidOut, let config, viewHeight > EventGridLayout.headerHeight else { return }
        let cards = Set(laidOut.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + viewHeight)).map(\.id))
        var calls: [() -> Void] = []
        if cards != told {
            told = cards
            calls.append { config.onVisible(cards) }
            EventPictures.prefetch(laidOut.cards(in: (offset - 3 * viewHeight) ... (offset + 4 * viewHeight))
                .compactMap { config.events[$0.id]?.snapshot })
        }
        let top = offset < 40
        if top != toldTop { toldTop = top; calls.append { config.onTop(top) } }
        let near = offset < GridMotion.farPanel * viewHeight
        if near != toldNear { toldNear = near; calls.append { config.onNear(near) } }
        let scrolled = offset > 1
        if scrolled != toldScrolled { toldScrolled = scrolled; calls.append { config.onScrolled(scrolled) } }
        let strip = (offset + viewHeight) ... (offset + viewHeight + bottomInset)
        let under = !laidOut.cards(in: strip).isEmpty
            || laidOut.headers.contains { $0.y + EventGridLayout.headerHeight >= strip.lowerBound && $0.y <= strip.upperBound }
        if under != toldUnder { toldUnder = under; calls.append { config.onUnderBottom(under) } }
        // (Not in the middle of the Events view's own update, which these change.)
        if !calls.isEmpty { DispatchQueue.main.async { calls.forEach { $0() } } }
    }

    // MARK: Moves

    /// Put at `y` at once.
    func land(at y: Double) {
        guard let laidOut else { return }
        stopGlide()
        steeredUntil = CACurrentMediaTime() + 0.1
        let target = laidOut.clamp(y, view: viewHeight)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolled to `y` with the SwiftUI grid's springy scroll (`EventGrid.bring`), a frame at a time (the scroll
    /// view's own place, so what's on screen is made as it goes); given up if it's scrolled meanwhile.
    func glide(to y: Double) {
        guard let laidOut else { return }
        stopGlide()
        let target = laidOut.clamp(y, view: viewHeight)
        let link = displayLink(target: self, selector: #selector(glideStep))
        link.add(to: .main, forMode: .common)
        gliding = (offset, target, CACurrentMediaTime(), link)
    }

    static let bring = Spring(duration: 0.62, bounce: 0.2)

    @objc fileprivate func glideStep(_ link: CADisplayLink) {
        guard let g = gliding else { return link.invalidate() }
        let t = CACurrentMediaTime() - g.began
        let done = t >= Self.bring.settlingDuration
        let p = done ? 1 : Self.bring.value(target: 1.0, time: t)
        steeredUntil = CACurrentMediaTime() + 0.1
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: g.from + (g.to - g.from) * p))
        scroll.reflectScrolledClipView(scroll.contentView)
        if done { stopGlide() }
    }

    fileprivate func stopGlide() {
        gliding?.link.invalidate()
        gliding = nil
    }

    @objc fileprivate func scrolledByHand() { stopGlide() }

    /// The scroll that keeps the top card on screen (one that's still there) where it is, laid out as now.
    func anchored(from before: EventGridLayout) -> Double {
        guard let laidOut else { return offset }
        let on = before.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + max(viewHeight, EventGridLayout.headerHeight)))
        guard let first = on.first(where: { laidOut.cards[$0.id] != nil }), let now = laidOut.cards[first.id] else {
            return laidOut.clamp(offset, view: viewHeight)
        }
        return laidOut.clamp(offset + (now.minY - first.frame.minY), view: viewHeight)
    }

    /// The top card on screen, and how far down the view it is.
    func place(in layout: EventGridLayout) -> (id: String, y: Double)? {
        let on = layout.cards(in: (offset + EventGridLayout.headerHeight) ... (offset + max(viewHeight, EventGridLayout.headerHeight)))
        return on.first.map { ($0.id, Double($0.frame.minY) - offset) }
    }

    /// The pictures of the cards about a screen either side of `y`.
    func pictures(around y: Double) -> [URL] {
        guard let laidOut, let config else { return [] }
        return laidOut.cards(in: (y - viewHeight) ... (y + 2 * viewHeight)).compactMap { config.events[$0.id]?.snapshot }
    }

    /// The panel opened or closed: the chosen card's row to the middle (or the top card kept), the grid zooming
    /// there from the cards as they were (see `zoom`).
    private func panelChanged(from before: EventGridLayout) {
        guard let laidOut, let config else { return }
        let shift = motion.panelChanged(open: config.panelOpen, leading: config.leading)
        let here = anchored(from: before)
        switch GridMotion.panelPlan(centred: config.focus.flatMap { laidOut.centring($0, view: viewHeight) }, here: here, view: viewHeight) {
        case let .reshape(to):
            zoom(from: before, to: to, shiftX: shift)
        case let .reshapeThenJump(here, to):
            // The cards reshape where they are, and the grid's jump leads out as they settle (see `EventGrid`).
            holdClicks()
            zoom(from: before, to: here, shiftX: shift)
            let open = config.panelOpen
            DispatchQueue.main.asyncAfter(deadline: .now() + EventGrid.reshapeTakes * EventGrid.leaveAfterPanel) { [self] in
                guard self.config?.panelOpen == open, motion.veil == nil else { return motion.settled() }
                jump(to: to)
            }
        }
    }

    /// Events came or went: a swap's landed where it goes (unseen, under its veil); otherwise what's on screen
    /// kept where it is.
    private func eventsChanged(from before: EventGridLayout) {
        guard let laidOut else { return }
        if let swap = motion.takeSwap() {
            // (Back where it was before a search, its top card where it was in the view, if it's still there.)
            let back = swap.back.flatMap { b in laidOut.cards[b.id].map { Double($0.minY) - b.y } }
            let target = laidOut.clamp(back ?? (swap.top ? 0 : anchored(from: before)), view: viewHeight)
            landDrawn(at: target, short: swap.drawnAt)
            return swap.landed(pictures(around: target))
        }
        move(from: before, to: offset > 40 ? anchored(from: before) : laidOut.clamp(offset, view: viewHeight))
    }

    /// Events came or went (`EventGrid.move`): the scroll put at once at `target` (what's on screen kept where it
    /// is), and each card on screen drawn moving from where it was on screen to where it now goes, by the panel's
    /// spring; new ones (just come in) grow in, those gone shrink away. Begun part way through another, from where
    /// that one had them.
    private func move(from before: EventGridLayout, to target: Double) {
        guard let laidOut, let config else { return }
        endZoom()
        let beforeOffset = offset
        let near = max(300, viewHeight * 0.5)
        // Where each card on screen is drawn now (its place, and how far a move under way has it from there).
        var was: [String: CGRect] = [:]
        var leaving: [GridCardView] = []
        for (id, card) in cards where !card.isHidden {
            let drawn = card.frame.offsetBy(dx: Self.drawnShift(card.layer).x, dy: Self.drawnShift(card.layer).y)
            if laidOut.cards[id] != nil {
                was[id] = drawn
            } else if before.cards[id] != nil, drawn.maxY >= beforeOffset - near, drawn.minY <= beforeOffset + viewHeight + near + topInset {
                // Gone: shrinks away where it is.
                leaving.append(card)
                cards[id] = nil
            }
        }
        var headersWere: [Date: CGRect] = [:]
        for (day, host) in headers {
            headersWere[day] = host.frame.offsetBy(dx: Self.drawnShift(host.layer).x, dy: Self.drawnShift(host.layer).y)
        }
        land(at: target)
        refresh()
        let dy = offset - beforeOffset
        let spring = { () -> CASpringAnimation in
            let a = CASpringAnimation(perceptualDuration: EventGrid.panelSpring.duration, bounce: 0)
            a.duration = a.settlingDuration
            return a
        }
        func from(_ layer: CALayer?, frame: CGRect, drawnAt: CGRect, key: String, after delay: Double, lift: Bool = false) {
            guard let layer, drawnAt.origin != frame.origin else { return }
            if lift { self.lift(layer, by: hypot(drawnAt.minX - frame.minX, drawnAt.minY - frame.minY), after: delay) }
            let a = spring()
            a.keyPath = "transform"
            a.fromValue = Self.moving(layer, from: frame, to: drawnAt, scale: 1)
            a.toValue = CATransform3DIdentity
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            layer.add(a, forKey: key)
        }
        // In turn: those gone fade out (out of focus as they go); then those staying move; then those come (or
        // now shown: a filter's taken off) fade in, coming into focus. (All at once, the new ones were simply there
        // as the others went.)
        let moving = cards.contains { id, card in !card.isHidden && was[id].map { $0.origin.y + dy != card.frame.minY || $0.minX != card.frame.minX } == true }
        let moveAt = leaving.isEmpty ? 0 : Self.fadeOut * 0.7
        let inAt = moving ? moveAt + Self.settleAfter : (leaving.isEmpty ? 0 : Self.fadeOut)
        for card in leaving {
            card.frame = card.frame.offsetBy(dx: 0, dy: dy)
            fade(card, in: false, after: 0, over: Self.fadeOut)
        }
        for (id, card) in cards where !card.isHidden {
            if let at = was[id] {
                // (Kept where it was on screen: the scroll moved under it.)
                from(card.layer, frame: card.frame, drawnAt: at.offsetBy(dx: 0, dy: dy), key: "flip", after: moveAt, lift: true)
            } else {
                fade(card, in: true, after: inAt, over: Self.fadeIn)
            }
        }
        for (day, host) in headers {
            if let at = headersWere[day] {
                from(host.layer, frame: host.frame, drawnAt: at.offsetBy(dx: 0, dy: dy), key: "flip", after: moveAt)
            } else {
                fade(host, in: true, after: inAt, over: Self.fadeIn)
            }
        }
        let gone = leaving
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut) { [weak self] in
            for card in gone {
                card.layer?.removeAllAnimations()
                card.layer?.filters = nil
                card.isHidden = true
                self?.spare.append(card)
            }
        }
        _ = config
    }

    /// A card lifted off the grid while it moves: over those it passes (higher the further it's going), a shadow
    /// under it, set down as it lands. (Level with them, crossing, their glassy backgrounds ran into each other.)
    fileprivate func lift(_ layer: CALayer, by distance: Double, after delay: Double) {
        let lasts = CASpringAnimation(perceptualDuration: EventGrid.panelSpring.duration, bounce: 0).settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = 1 + min(distance, 4000) / 4000
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = 10
        // (Down, as SwiftUI's shadow(y: 3) is: up's positive in an unflipped layer.)
        layer.shadowOffset = CGSize(width: 0, height: (layer.superlayer?.contentsAreFlipped() ?? true) ? 3 : -3)
        layer.shadowPath = GridCardView.continuous(layer.bounds, radius: GridCardView.corner)
        layer.shadowOpacity = 0
        CATransaction.commit()
        let shadow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shadow.values = [0, 0.35, 0.35, 0]
        shadow.keyTimes = [0, 0.15, 0.7, 1]
        shadow.duration = lasts
        shadow.beginTime = CACurrentMediaTime() + delay
        layer.add(shadow, forKey: "lift")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + lasts) { [weak layer] in
            guard let layer, layer.animation(forKey: "lift") == nil else { return }
            layer.zPosition = 0
        }
    }

    /// The fades either side of a move of the cards, and when the move's far enough on for those coming to fade in.
    static let fadeOut = 0.18, fadeIn = 0.22, settleAfter = 0.3

    /// A card (or header) faded in, coming into focus, or out, going out of it: the grid's veil's way, one at a time.
    fileprivate func fade(_ view: NSView, in coming: Bool, after delay: Double, over duration: Double) {
        guard let layer = view.layer else { return }
        view.layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(coming ? EventGrid.veilBlur : 0, forKey: kCIInputRadiusKey)
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = coming ? 0 : 1
        fade.toValue = coming ? 1 : 0
        let focus = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        focus.fromValue = coming ? EventGrid.veilBlur : 0
        focus.toValue = coming ? 0 : EventGrid.veilBlur
        for a in [fade, focus] {
            a.duration = duration
            a.beginTime = begin
            a.fillMode = .backwards
            a.timingFunction = CAMediaTimingFunction(name: coming ? .easeOut : .easeIn)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.filters = [blur]
        layer.opacity = coming ? 1 : 0
        layer.setValue(coming ? 0 : EventGrid.veilBlur, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
        layer.add(fade, forKey: "fade")
        layer.add(focus, forKey: "fade.blur")
        // (Its filter let go once it's in: a filter on every card, still, costs each frame.)
        if coming {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.05) { [weak layer] in
                guard let layer, layer.animation(forKey: "fade") == nil else { return }
                layer.filters = nil
            }
        }
    }

    /// A card coming in (growing in from its middle, fading in) or going (shrinking away, fading), by the panel's
    /// spring (`EventGrid.appear`).
    private func appear(_ card: GridCardView, coming: Bool) {
        guard let layer = card.layer else { return }
        let small = card.frame.insetBy(dx: card.frame.width * 0.075, dy: card.frame.height * 0.075)
        let shrunk = Self.moving(layer, from: card.frame, to: small, scale: 0.85)
        let grow = CASpringAnimation(perceptualDuration: EventGrid.panelSpring.duration, bounce: 0)
        grow.keyPath = "transform"
        grow.fromValue = coming ? shrunk : CATransform3DIdentity
        grow.toValue = coming ? CATransform3DIdentity : shrunk
        grow.duration = grow.settlingDuration
        let fade = CASpringAnimation(perceptualDuration: EventGrid.panelSpring.duration, bounce: 0)
        fade.keyPath = "opacity"
        fade.fromValue = coming ? 0 : 1
        fade.toValue = coming ? 1 : 0
        fade.duration = fade.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = coming ? CATransform3DIdentity : shrunk
        layer.opacity = coming ? 1 : 0
        CATransaction.commit()
        layer.add(grow, forKey: "appear")
        layer.add(fade, forKey: "appear.fade")
    }

    /// How far a layer's drawn from its view's place just now (a move under way), in the view's (flipped) terms.
    static func drawnShift(_ layer: CALayer?) -> CGPoint {
        guard let layer, let t = layer.presentation()?.transform else { return .zero }
        let flipped = layer.superlayer?.contentsAreFlipped() ?? true
        return CGPoint(x: t.m41, y: flipped ? t.m42 : -t.m42)
    }

    /// Those come during a far jump, in once it's settled.
    fileprivate func letWaitingIn() {
        guard let config, let was = motion.letIn(now: config.sections) else { return }
        let before = cache.layout(sections: was, width: config.width - gutter, columns: config.columns)
        laidOut = cache.layout(sections: config.sections, width: config.width - gutter, columns: config.columns)
        sizeDocument()
        eventsChanged(from: before)
        refresh()
    }

    /// The sections drawn: those shown, or, a far jump under way, those it began with (those come since wait).
    var drawnSections: [EventGridLayout.Section] { motion.waiting ?? config?.sections ?? [] }

    /// The window resized: the card at the top as it began kept where it was, every step.
    private func resized(from before: EventGridLayout) {
        guard let laidOut, let anchor = motion.resizing(from: place(in: before)), let card = laidOut.cards[anchor.id] else { return }
        land(at: Double(card.minY) - anchor.y)
        let step = UUID()
        resizeStep = step
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if self?.resizeStep == step { self?.motion.resized() }
        }
    }

    func perform(_ request: GridScroll) {
        guard let laidOut else { return }
        // (A far jump under way gives way to this: shown again at once.)
        if motion.interrupt() { unveil() }
        switch request.kind {
        case .top:
            if !request.animated { land(at: 0) } else if GridMotion.isFar(from: offset, to: 0, view: viewHeight) { jump(to: 0) } else { glide(to: 0) }
        case let .swap(top):
            // (Going into a search: where it is kept, to come back to; out of one, back there.)
            if request.remember { motion.remembered = place(in: laidOut) }
            swap(request.change ?? { false }, top: top, back: request.restore ? motion.remembered : nil)
        case let .centre(id, always):
            let target: Double
            if always {
                guard let centred = laidOut.centring(id, view: viewHeight) else { return }
                target = centred
            } else {
                let margin = 0.4 * (laidOut.cards[id]?.height ?? 200)
                guard let revealed = laidOut.revealing(id, offset: offset, view: viewHeight, top: EventGridLayout.headerHeight,
                                                      margin: margin) else { return }
                target = revealed
            }
            if !request.animated { land(at: target) } else if GridMotion.isFar(from: offset, to: target, view: viewHeight) { jump(to: target) } else { glide(to: target) }
        }
    }

    /// The Now (or Top) button: back up, letting in those held back.
    private func backUp() {
        guard let config else { return }
        if let letIn = config.letIn, config.newWaiting > 0 {
            jump(to: 0, change: letIn)
        } else {
            perform(GridScroll(kind: .top))
        }
    }

    // MARK: Scrolling fast

    /// The scroll's speed, as it goes: fast enough for long enough, the cards are plain blocks, dimmed; slower
    /// again, or still a moment, the pictures where it's stopped are read and they're shown again. The grid's own
    /// scrolls don't count.
    fileprivate func track() {
        let now = CACurrentMediaTime(), y = offset
        defer { speed.last = (y, now) }
        guard let last = speed.last, now > last.t, now > steeredUntil, motion.veil == nil, zooming == nil, viewHeight > 0 else {
            speed.value = 0
            speed.fast = 0
            return
        }
        let screens = abs(y - last.y) / (now - last.t) / viewHeight
        speed.value = speed.value * 0.5 + screens * 0.5
        speed.fast = speed.value > EventGrid.scrubStarts ? speed.fast + 1 : 0
        if !scrubbing {
            // (More than a screen at a step, the scroll thumb dragged: at once.)
            guard speed.fast >= 2 || abs(y - last.y) > viewHeight else { return }
            scrub(true)
        }
        placeScrubLabel()
        if speed.value >= EventGrid.scrubEnds {
            settleToken = nil
            // Still a moment (the scroller held where it is): as slowed.
            speed.beat += 1
            let beat = speed.beat
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in if self?.speed.beat == beat { self?.settle() } }
        } else {
            settle()
        }
    }

    fileprivate func settle() {
        guard scrubbing, settleToken == nil else { return }
        let token = UUID()
        settleToken = token
        let show = { [weak self] in
            guard let self, self.settleToken == token, self.scrubbing else { return }
            self.settleToken = nil
            self.scrub(false)
        }
        EventPictures.prefetch(pictures(around: offset)) { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { show() }
    }

    /// The cards plain blocks, dimmed, the day and hour shown over them (or themselves again).
    fileprivate func scrub(_ on: Bool) {
        scrubbing = on
        for card in cards.values where !card.isHidden { card.setBlocked(on, animated: true) }
        let duration = on ? 0.15 : 0.2
        if let layer = document.layer {
            GridCardView.change(layer, "opacity", to: Float(on ? 0.5 : 1), animated: true, duration: duration)
        }
        placeScrubLabel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            scrubLabel.animator().alphaValue = on ? 1 : 0
        }
        if let layer = scrubLabel.layer {
            // (About its middle.)
            let f = scrubLabel.frame
            let small = Self.moving(layer, from: f, to: f.insetBy(dx: f.width * 0.03, dy: f.height * 0.03), scale: 0.94)
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = on ? small : CATransform3DIdentity
            a.toValue = on ? CATransform3DIdentity : small
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "scrub")
        }
    }

    /// Where it's got to, in the middle: the day and hour of the card nearest the middle of the screen.
    fileprivate func placeScrubLabel() {
        guard scrubbing, let laidOut, let config else { return }
        let mid = offset + viewHeight / 2
        let near = laidOut.cards(in: (mid - viewHeight / 2) ... (mid + viewHeight / 2))
        guard let event = near.min(by: { abs($0.frame.midY - mid) < abs($1.frame.midY - mid) }).flatMap({ config.events[$0.id] }) else { return }
        // (In a room larger than it, in its middle: sized by the hosting view, it was measured before its words
        // were in it, and drawn as an empty capsule.)
        scrubLabel.rootView = AnyView(ScrubLabel(day: config.title(Calendar.current.startOfDay(for: event.start)), hour: event.start)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false))
        let size = CGSize(width: 420, height: 160)
        scrubLabel.frame = CGRect(x: bounds.midX - size.width / 2, y: topInset + viewHeight / 2 - size.height / 2,
                                  width: size.width, height: size.height)
    }

    // MARK: Far jumps and swaps: the grid faded out (and out of focus) and in again

    /// The cards not clicked until a far jump's settled (and events come meanwhile held); let go after a few
    /// seconds whatever.
    fileprivate func holdClicks() {
        guard let config else { return }
        motion.holdClicks(now: CACurrentMediaTime(), showing: config.sections)
        DispatchQueue.main.asyncAfter(deadline: .now() + GridMotion.settleFor + 0.05) { [weak self] in
            self?.motion.timedOut(now: CACurrentMediaTime())
            self?.letWaitingIn()
        }
    }

    /// Far away: the grid eases off the way it's going as it fades out, is there at once (a little short of it),
    /// and fades in again once the pictures there are read, easing the last of the way (`EventGrid.jump`).
    fileprivate func jump(to target: Double, change: GridChange? = nil) {
        guard let laidOut else { return }
        endZoom()
        stopGlide()
        let down = target > offset, lead = EventGrid.jumpLead
        let away = laidOut.clamp(offset + (down ? lead : -lead), view: viewHeight)
        let from = laidOut.clamp(target + (down ? -lead : lead), view: viewHeight)
        let out = abs(away - offset), in_ = abs(target - from)
        let ease = JumpEase.timings(leaving: out, arriving: in_, over: EventGrid.jumpTakes * (0.5 + 0.5 * (out + in_) / (2 * lead)))
        if let leave = ease.leave { shiftContent(to: offset - away, over: ease.leaveFor, timing: leave) }
        holdClicks()
        veil(reading: pictures(around: target), fadingOut: ease.leave == nil ? 0.12 : ease.leaveFor) { [self] current, landed in
            guard current else { _ = change?(); return }
            let short = ease.arrive == nil ? nil : from
            // The events changing as it goes (those held back, at the top): changed unseen, landed on as they are.
            if let change {
                return changing(Swapping(top: target == 0, drawnAt: short, landed: landed), by: change) { [self] in
                    landDrawn(at: target, short: short)
                    landed([])
                }
            }
            landDrawn(at: target, short: short)
            landed([])
        } shown: { [self] in
            guard let arrive = ease.arrive else { return motion.settled() }
            shiftContent(to: 0, over: ease.arriveFor, timing: arrive) { [self] in
                if motion.veil == nil { motion.settled() }
                letWaitingIn()
            }
        }
    }

    /// The events changing wholesale (a search, its order): faded out (and out of focus), changed, shown at once
    /// where they go (`eventsChanged`), faded in.
    fileprivate func swap(_ change: @escaping GridChange, top: Bool, back: (id: String, y: Double)?) {
        // (A little longer going than a jump's: its blur seen, not just a blink.)
        veil(fadingOut: 0.18) { [self] current, landed in
            guard current else { _ = change(); return }
            let swap = Swapping(top: top, landed: landed)
            swap.back = back
            changing(swap, by: change) { landed([]) }
        }
    }

    /// A change made under the veil: the grid's events changed, landed as they come; else `unchanged`, at once
    /// (and if they never come, a second on, whatever).
    fileprivate func changing(_ swap: Swapping, by change: GridChange, unchanged: @escaping @MainActor () -> Void) {
        motion.swapping = swap
        guard change() else {
            motion.swapping = nil
            return unchanged()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.motion.swapping === swap else { return }
            self.motion.swapping = nil
            unchanged()
        }
    }

    /// There at once, drawn as if still at `short` (a far jump's lead-in to come).
    fileprivate func landDrawn(at target: Double, short: Double?) {
        land(at: target)
        shiftContent(to: short.map { target - $0 } ?? 0)
    }

    /// Faded out; `land` then, unseen (told whether this is still the latest, and given what to call once it's
    /// landed, with the pictures it lands on, to be read); faded in once it's landed and those are read, or after
    /// half a second whatever (past a fifth, a spinner says so); `shown` as it fades in.
    fileprivate func veil(reading early: [URL] = [], fadingOut: Double = 0.12,
                          land: @escaping @MainActor (_ current: Bool, _ landed: @escaping @MainActor ([URL]) -> Void) -> Void,
                          shown: (@MainActor () -> Void)? = nil) {
        let id = motion.beginVeil()
        final class Progress { var landed = false, reads = 0, shown = false }
        let progress = Progress()
        func showIfReady(waited: Bool = false) {
            guard motion.isCurrent(id), progress.landed, progress.reads == 0 || waited, !progress.shown else { return }
            progress.shown = true
            veiling(false, over: 0.2, timing: CAMediaTimingFunction(name: .easeOut))
            spinner.stopAnimation(nil)
            motion.endVeil(id)
            shown?()
            letWaitingIn()
        }
        func read(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            progress.reads += 1
            EventPictures.prefetch(urls) {
                progress.reads -= 1
                showIfReady()
            }
        }
        read(early)
        veiling(true, over: fadingOut, timing: CAMediaTimingFunction(name: .easeIn)) { [self] in
            land(motion.isCurrent(id)) { [self] urls in
                read(urls)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    progress.landed = true
                    showIfReady()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    if motion.isCurrent(id), !progress.shown { placeSpinner(); spinner.startAnimation(nil) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showIfReady(waited: true) }
            }
        }
    }

    /// Shown again at once (a veil given up).
    fileprivate func unveil() {
        veiling(false, over: 0, timing: CAMediaTimingFunction(name: .linear))
        shiftContent(to: 0)
        spinner.stopAnimation(nil)
    }

    /// The grid (and the pinned day) faded and blurred out, or in, as the SwiftUI grid's `veiled` did.
    fileprivate func veiling(_ on: Bool, over duration: Double, timing: CAMediaTimingFunction, then done: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done?() } }
        for layer in [scroll.contentView.layer, pinned.layer].compactMap({ $0 }) {
            let to: (opacity: Float, blur: Double) = on ? (0, EventGrid.veilBlur) : (1, 0)
            if duration > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = to.opacity
                let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
                blur.fromValue = layer.presentation()?.value(forKeyPath: "filters.blur.inputRadius") ?? 0
                blur.toValue = to.blur
                for a in [fade, blur] {
                    a.duration = duration
                    a.timingFunction = timing
                }
                layer.add(fade, forKey: "veil.fade")
                layer.add(blur, forKey: "veil.blur")
            } else {
                layer.removeAnimation(forKey: "veil.fade")
                layer.removeAnimation(forKey: "veil.blur")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = to.opacity
            layer.setValue(to.blur, forKeyPath: "filters.blur.inputRadius")
            CATransaction.commit()
        }
        CATransaction.commit()
    }

    /// The cards drawn `y` lower than the scroll has them (a far jump's leaving and arriving), eased there.
    fileprivate func shiftContent(to y: Double, over duration: Double = 0, timing: CAMediaTimingFunction? = nil,
                                  then done: (@MainActor () -> Void)? = nil) {
        guard let layer = document.layer else { done?(); return }
        let to = Self.moving(layer, from: document.frame, to: document.frame.offsetBy(dx: 0, dy: y), scale: 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done?() } }
        if duration > 0 {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = layer.presentation()?.transform ?? layer.transform
            a.toValue = to
            a.duration = duration
            a.timingFunction = timing
            layer.add(a, forKey: "shift")
        } else {
            layer.removeAnimation(forKey: "shift")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        CATransaction.commit()
        CATransaction.commit()
    }

    /// The spinner, in the middle of the room between the bars.
    fileprivate func placeSpinner() {
        let size = spinner.fittingSize
        spinner.frame = CGRect(x: bounds.midX - size.width / 2, y: topInset + viewHeight / 2 - size.height / 2,
                               width: size.width, height: size.height)
    }

    // MARK: Clicks, the pointer, the menu

    func card(at point: NSPoint) -> (id: String, view: GridCardView)? {
        for (id, card) in cards where !card.isHidden && card.frame.contains(point) { return (id, card) }
        return nil
    }

    func clicked(at point: NSPoint, count: Int) {
        // (Not early in the zoom: nearly still, it is. Nor while a far jump settles.)
        if let zooming, zooming.progress < GridMotion.clickableAfter { return }
        if motion.settling { return }
        guard let config, let hit = card(at: point), let event = config.events[hit.id] else { return }
        if count >= 2 {
            if event.pond == nil { config.open(event) } else { config.choose(event) }
        } else if count == 1 {
            config.choose(event)
        }
    }

    func hovering(at point: NSPoint?) {
        let id = point.flatMap { card(at: $0)?.id }
        guard id != hovered else { return }
        if let hovered { cards[hovered]?.hovering = false }
        hovered = id
        if let id { cards[id]?.hovering = true }
        onHoverCard?(id.flatMap { config?.events[$0] })
    }

    /// The card under the pointer (its event), as it changes: for the Events shell to ready its panel.
    var onHoverCard: ((TimelineEvent?) -> Void)?

    func menu(at point: NSPoint) -> NSMenu? {
        guard let config, let hit = card(at: point), let event = config.events[hit.id] else { return nil }
        let menu = NSMenu()
        func item(_ title: String, symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if event.pond == nil { item("Watch on the Timeline") { config.open(event) } }
        if let snapshot = event.snapshot {
            item("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
        }
        if event.pond == nil {
            menu.addItem(.separator())
            if event.quieted != nil {
                item("It Was Something", symbol: "exclamationmark.bubble") { [model] in model.say(.something, of: event) }
            } else {
                item("This Wasn\u{2019}t Anything", symbol: "moon.zzz") { [model] in model.say(.nothing, of: event) }
            }
            menu.addItem(.separator())
            item("Ignore This Area\u{2026}", symbol: "eye.slash", enabled: model.canEditZones(event.camera) && event.box != nil) { [model] in
                model.editZones(event.camera, ignoring: event)
            }
            item("Edit Zones\u{2026}", symbol: "square.dashed", enabled: model.canEditZones(event.camera)) { [model] in model.editZones(event.camera) }
            item("Camera Settings\u{2026}", symbol: "gearshape") { [model] in model.editCameraSettings(event.camera) }
            menu.addItem(.separator())
            item("Delete Event\u{2026}") { config.delete(event) }
        }
        return menu
    }
}

/// The scroll view's content: the cards and headers, from the top (flipped), and what the pointer does over them.
final class GridDocumentView: NSView {
    weak var host: GridHostView?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { host?.hovering(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { host?.hovering(at: nil) }
    override func mouseDown(with event: NSEvent) { host?.clicked(at: convert(event.locationInWindow, from: nil), count: event.clickCount) }
    override func menu(for event: NSEvent) -> NSMenu? { host?.menu(at: convert(event.locationInWindow, from: nil)) }
}

/// A hosted SwiftUI view that lets clicks through everywhere but `clickable` (its own terms: what it draws there, a
/// row of capsules). (SwiftUI's controls aren't views of their own: told apart by what's hit, a click on a button
/// was let through too, to the card under it.)
final class PassThroughHosting<Content: View>: NSHostingView<Content> {
    var clickable: CGRect?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let clickable, !isHidden, alphaValue > 0, clickable.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// A menu item that does what it's given.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(go), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func go() { run() }
}

/// A day's header, as `EventGrid.header` draws it: its glass capsule (the day, how many), and, pinned and scrolled
/// down, the way back up beside it.
struct GridDayHeader: View, Equatable {
    var title = ""
    var count = 0
    var now = false
    var newWaiting = 0
    var byBestMatch = false
    var back: () -> Void = {}
    var capsule: (Double) -> Void = { _ in }
    /// Where its row is (the capsules), to be clicked there.
    var row: (CGRect) -> Void = { _ in }

    static let empty = GridDayHeader()

    nonisolated static func == (a: GridDayHeader, b: GridDayHeader) -> Bool {
        a.title == b.title && a.count == b.count && a.now == b.now && a.newWaiting == b.newWaiting && a.byBestMatch == b.byBestMatch
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.bold))
                Text(count == 1 ? "1 event" : "\(count) events")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { capsule($0) }
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
            if now {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up")
                        Text(byBestMatch ? "Top" : "Now")
                        if newWaiting > 0 {
                            Text("\(newWaiting) new").monospacedDigit().foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(newWaiting)))
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(newWaiting > 0 ? .regular.tint(Color.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
                             in: .capsule)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                .help(byBestMatch ? "Back to the best match" : newWaiting > 0 ? "Back to the newest events, and the new ones since" : "Back to the newest events")
                .transition(.opacity)
                .animation(.snappy(duration: 0.25), value: newWaiting)
            }
        }
        .animation(.easeOut(duration: 0.15), value: now)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { row($0) }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .coordinateSpace(.named(Self.space))
    }

    nonisolated static let space = "dayHeader"
}

// MARK: - The panel's zoom

/// The zoom's geometry, as `EventGrid.canvas` works it out: from the grid as it was to as it is, each layer scaled to
/// the width part way between, from the left edge going with the rail; up and down, about the card both are drawn
/// about (see `GridReshape`).
struct GridZoom {
    let beforeWidth: Double
    let nowWidth: Double
    let dx: Double
    /// The anchor card's top in the old layer (as drawn, moved by `dy`) and in the new.
    let was: Double?
    let is_: Double?

    init(_ r: GridReshape, now: EventGridLayout, dy: Double) {
        beforeWidth = r.before.width
        nowWidth = now.width
        dx = r.dx
        was = r.anchor.flatMap { r.before.cards[$0] }.map { Double($0.minY) + dy }
        is_ = r.anchor.flatMap { now.cards[$0] }.map { Double($0.minY) }
    }

    /// Where a layer's drawn `p` of the way: the old one (drawn moved over by `dx`) or the new.
    func transform(_ p: Double, old: Bool) -> CGAffineTransform {
        let width = old ? beforeWidth : nowWidth
        guard width > 0 else { return .identity }
        let wide = beforeWidth + (nowWidth - beforeWidth) * p
        let k = wide / width
        let left = dx * (1 - p)
        let anchor = old ? was : is_
        let at = was.flatMap { w in is_.map { w + ($0 - w) * p } }
        return CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: left - (old ? dx : 0) * k,
                                 ty: anchor.flatMap { a in at.map { $0 - a * k } } ?? 0)
    }
}

/// A layer of the zoom: the cards as they were, or as they are, in a stage the size of what's on screen (and a
/// margin), blurred and faded as one (as SwiftUI blurs a view: the cards' edges soft too), never clicked.
final class GridStage: NSView {
    /// Where it is in the grid's document (it's drawn over the scroll view, outside it, so the cards in it aren't
    /// cut off at its edge: the old cards are wider, and over to the side, as the zoom begins).
    var docOrigin = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        layer?.filters = [blur]
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The zoom under way: its layers, the cards as they were (gone after), the phase it runs over, and what's done
/// at each frame of it.
struct Zooming {
    let id = UUID()
    let clip: ZoomClip
    let old: GridStage
    let new: GridStage
    let ghosts: [GridCardView]
    let staged: [GridCardView]
    let began = CACurrentMediaTime()

    /// How far it's got (the spring's value now).
    var progress: Double { GridHostView.zoomSpring.value(target: 1.0, time: CACurrentMediaTime() - began) }
}

/// Over the grid through the zoom: clipped at the top and the bottom, not the sides (the toolbar's above, and the
/// old cards wider, over to the sides, as it begins; `EventGrid`'s mask, likewise).
final class ZoomClip: NSView {
    static let reach = 3000.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension GridHostView {
    /// The grid's width changed with the panel: the cards as they were (where they were on screen), under the cards
    /// as they are now at `target`, which fade in over them as both zoom from the old width to the new about the
    /// card both are drawn about; then the old are let go. (See `GridReshape`.) Run by Core Animation, by keyframes
    /// sampled from the SwiftUI grid's own curve and measures, begun in the same moment as the panel's and the rail's
    /// moves (`EventsShell`), on the same curve.
    /// (The cards a row not as many as they were: there at once, no zoom: zoomed, the rows came apart; crossfaded, it
    /// was heavy, for a change made by the window's size.)
    fileprivate func zoom(from before: EventGridLayout, to target: Double, shiftX dx: Double) {
        endZoom()
        guard let laidOut, let config, before.columns == laidOut.columns else { return land(at: target) }
        stopGlide()
        let beforeOffset = offset
        let onScreen = before.cards(in: (beforeOffset + EventGridLayout.headerHeight) ... (beforeOffset + max(viewHeight, EventGridLayout.headerHeight)))
        let anchor = config.focus.flatMap { laidOut.cards[$0] != nil && before.cards[$0] != nil ? $0 : nil }
            ?? onScreen.first { laidOut.cards[$0.id] != nil }?.id
        // The cards on screen as they were: kept for the old layer (those far off let go).
        let moveMargin = max(300, viewHeight * 0.5)
        let near = (beforeOffset - moveMargin) ... (beforeOffset + viewHeight + moveMargin)
        var ghosts: [GridCardView] = []
        for (id, card) in cards {
            if !card.isHidden, let f = before.cards[id], f.maxY >= near.lowerBound, f.minY <= near.upperBound {
                ghosts.append(card)
            } else {
                card.isHidden = true
                spare.append(card)
            }
        }
        cards = [:]
        // The headers' places as they were (in the layout), for those to move from.
        let headersBefore = Dictionary(before.headers.map { ($0.day, $0.y) }, uniquingKeysWith: { a, _ in a })
        land(at: target)
        refresh()
        let dy = offset - beforeOffset
        let r = GridReshape(before: before, anchor: anchor, beforeOffset: beforeOffset, dx: dx, start: 0, began: Date())
        let z = GridZoom(r, now: laidOut, dy: dy)

        // Over the scroll view, not in it (its clip view would cut the old, wider cards off at its sides, where
        // SwiftUI's let them run on: `scrollClipDisabled`), in a clip at the grid's top and bottom only.
        let clipView = ZoomClip(frame: CGRect(x: -ZoomClip.reach, y: 0, width: bounds.width + 2 * ZoomClip.reach, height: bounds.height))
        addSubview(clipView, positioned: .above, relativeTo: scroll)
        let clip = scroll.contentView.bounds
        let stageRect = CGRect(x: min(0, dx) - 40, y: clip.minY - moveMargin,
                               width: max(before.width, laidOut.width) + abs(dx) + 80, height: clip.height + 2 * moveMargin)
        let shift = CGPoint(x: scroll.frame.minX - clip.minX + ZoomClip.reach, y: scroll.frame.minY - clip.minY)
        zoomShift = shift
        let inClip = stageRect.offsetBy(dx: shift.x, dy: shift.y)
        let old = GridStage(frame: inClip), new = GridStage(frame: inClip)
        old.docOrigin = stageRect.origin
        new.docOrigin = stageRect.origin
        clipView.addSubview(old)
        clipView.addSubview(new)
        for host in headers.values {
            let f = host.frame.offsetBy(dx: shift.x, dy: shift.y)
            host.removeFromSuperview()
            clipView.addSubview(host)
            host.frame = f
        }
        for g in ghosts {
            var f = g.frame
            f.origin.x += dx
            f.origin.y += dy
            g.removeFromSuperview()
            old.addSubview(g)
            g.frame = f.offsetBy(dx: -stageRect.minX, dy: -stageRect.minY)
        }
        var staged: [GridCardView] = []
        for card in cards.values where !card.isHidden && card.frame.intersects(stageRect) {
            let f = card.frame
            card.removeFromSuperview()
            new.addSubview(card)
            card.frame = f.offsetBy(dx: -stageRect.minX, dy: -stageRect.minY)
            staged.append(card)
        }
        scrollerFade(in: false)

        // At each point of the curve: each layer's cards (one transform a layer: the zoom's the same for every card
        // in it), faded and blurred; the headers going from where they were to where they are with the cards about
        // them, at their own size; the pinned day with the grid's left edge, the order's switch with its right.
        let topInset = self.topInset
        let headerMoves: [(PassThroughHosting<GridDayHeader>, was: Double, now: Double)] = headers.compactMap { day, host in
            guard let was = headersBefore[day], let now = laidOut.headers.first(where: { $0.day == day })?.y else { return nil }
            return (host, was, now)
        }
        let beforeWidth = before.width, nowWidth = laidOut.width
        let samples = Self.zoomSamples
        func keyframes(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.keyTimes = samples.times
            a.duration = samples.duration
            a.calculationMode = .linear
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            return a
        }
        // (Each layer's own value set to where it begins: a frame drawn before the animation's taken up shows it
        // begun, not done.)
        func run(_ layer: CALayer?, _ key: String, _ values: [Any]) {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(values.first, forKeyPath: key)
            CATransaction.commit()
            layer.add(keyframes(key, values), forKey: "zoom." + key)
        }
        let ps = samples.p
        run(old.layer, "sublayerTransform", ps.map { Self.stageTransform(old, z.transform($0, old: true), origin: stageRect.origin, topInset: topInset) })
        run(new.layer, "sublayerTransform", ps.map { Self.stageTransform(new, z.transform($0, old: false), origin: stageRect.origin, topInset: topInset) })
        run(old.layer, "opacity", ps.map { Float(GridReshape.old($0)) })
        run(new.layer, "opacity", ps.map { Float(GridReshape.new($0)) })
        for stage in [old, new] { run(stage.layer, "filters.blur.inputRadius", ps.map(GridReshape.blur)) }
        for (host, was, now) in headerMoves {
            guard let layer = host.layer else { continue }
            run(layer, "transform", ps.map { p -> CATransform3D in
                let a = CGPoint(x: dx, y: was + dy).applying(z.transform(p, old: true))
                let b = CGPoint(x: 0, y: now).applying(z.transform(p, old: false))
                let drawn = host.frame.offsetBy(dx: a.x + (b.x - a.x) * p, dy: (a.y + (b.y - a.y) * p) - now)
                return Self.moving(layer, from: host.frame, to: drawn, scale: 1)
            })
        }
        run(pinned.layer, "transform", ps.map { CATransform3DMakeTranslation(dx * (1 - $0), 0, 0) })
        run(order.layer, "transform", ps.map { p in
            let wide = beforeWidth + (nowWidth - beforeWidth) * p
            return CATransform3DMakeTranslation(dx * (1 - p) + wide - nowWidth, 0, 0)
        })
        zooming = Zooming(clip: clipView, old: old, new: new, ghosts: ghosts, staged: staged)
        let id = zooming?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + samples.duration) { [weak self] in
            if let id, self?.zooming?.id == id { self?.endZoom() }
        }
    }

    /// The zoom's curve: the SwiftUI grid's (`EventGrid.reshapeAnimation`, `.smooth`), which the panel's slide and
    /// the rail's go with (`EventsShell`).
    nonisolated static let zoomSpring = Spring(duration: 0.4, bounce: 0)

    /// The spring, sampled: when (of the whole), and how far it's got then.
    static let zoomSamples: (times: [NSNumber], p: [Double], duration: Double) = {
        let total = zoomSpring.settlingDuration
        let n = 90
        var times: [NSNumber] = [], p: [Double] = []
        for i in 0 ... n {
            times.append(NSNumber(value: Double(i) / Double(n)))
            p.append(i == n ? 1 : zoomSpring.value(target: 1.0, time: total * Double(i) / Double(n)))
        }
        return (times, p, total)
    }()

    /// A stage's sublayers' transform for the zoom's `t` (in the layout's terms): a card at `c` in the stage drawn
    /// at `t` of its place in the layout, back in the stage's terms; worked out in the stage layer's own geometry
    /// (its y up or down, its anchor at a corner).
    static func stageTransform(_ stage: GridStage, _ t: CGAffineTransform, origin: CGPoint, topInset: Double) -> CATransform3D {
        guard let layer = stage.layer else { return CATransform3DIdentity }
        let k = t.a
        // In the stage (flipped): c -> k c + u.
        let o = CGPoint(x: origin.x, y: origin.y - topInset)
        let u = CGPoint(x: (k - 1) * o.x + t.tx, y: (k - 1) * o.y + t.ty)
        let flipped = layer.contentsAreFlipped()
        let h = layer.bounds.height
        let a = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * h)
        // In the layer's own terms (y up, unless it's flipped), about its anchor.
        let tx = u.x + (k - 1) * a.x
        let ty = flipped ? u.y + (k - 1) * a.y : (h * (1 - k) - u.y) + (k - 1) * a.y
        return CATransform3DScale(CATransform3DMakeTranslation(tx, ty, 0), k, k, 1)
    }

    /// The transform that draws a view's layer, placed at `from` (in its superview, flipped: y down), at `to`,
    /// scaled `scale`: worked out in the layer's own geometry (AppKit's: its anchor at a corner, and its
    /// superlayer's y up or down as that's flipped or not), so the view's drawn where it's meant to be.
    static func moving(_ layer: CALayer, from: CGRect, to: CGRect, scale k: Double) -> CATransform3D {
        let flipped = layer.superlayer?.contentsAreFlipped() ?? true
        let h = layer.superlayer?.bounds.height ?? 0
        func inLayer(_ r: CGRect) -> CGRect { flipped ? r : CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        let f = inLayer(from), t = inLayer(to)
        let a = layer.anchorPoint
        let tx = t.minX - f.minX - a.x * f.width * (1 - k)
        let ty = t.minY - f.minY - a.y * f.height * (1 - k)
        return CATransform3DScale(CATransform3DMakeTranslation(tx, ty, 0), k, k, 1)
    }

    /// The zoom done (or given way to another move): the old cards let go, the new back in the grid, still.
    fileprivate func endZoom() {
        guard let z = zooming else { return }
        zooming = nil
        // (Still: each layer at rest, as the zoom left it.)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for host in headers.values {
            host.layer?.transform = CATransform3DIdentity
            host.layer?.opacity = 1
        }
        pinned.layer?.transform = CATransform3DIdentity
        order.layer?.transform = CATransform3DIdentity
        for layer in [z.old.layer, z.new.layer, pinned.layer, order.layer].compactMap({ $0 }) + headers.values.compactMap(\.layer) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("zoom.") { layer.removeAnimation(forKey: key) }
        }
        z.old.layer?.sublayerTransform = CATransform3DIdentity
        z.new.layer?.sublayerTransform = CATransform3DIdentity
        for card in z.staged + z.ghosts {
            let f = card.frame.offsetBy(dx: z.new.docOrigin.x, dy: z.new.docOrigin.y)
            card.removeFromSuperview()
            document.addSubview(card, positioned: .below, relativeTo: document.subviews.first { $0 is PassThroughHosting<GridDayHeader> })
            card.frame = f
        }
        // The headers back in the grid's document (placed again below).
        for host in headers.values where host.superview === z.clip {
            host.removeFromSuperview()
            document.addSubview(host)
        }
        zoomShift = nil
        for g in z.ghosts {
            g.isHidden = true
            spare.append(g)
        }
        z.clip.removeFromSuperview()
        // Its scroller back, once it's still: shown where it is now, fading in there, then left to fade as it does.
        scroll.flashScrollers()
        scrollerFade(in: true)
        refresh()
    }

    /// The scroller faded out (the grid zooming: the scroll's put where it ends at once, and the scroller jumped
    /// there alone), or in. (Its layer: an overlay scroller's own alpha is AppKit's, and it took no notice.)
    fileprivate func scrollerFade(in coming: Bool) {
        guard let scroller = scroll.verticalScroller else { return }
        scroller.wantsLayer = true
        guard let layer = scroller.layer else { return }
        let to: Float = coming ? 1 : 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = to
        a.duration = coming ? 0.25 : 0.12
        a.timingFunction = CAMediaTimingFunction(name: coming ? .easeOut : .easeIn)
        layer.add(a, forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
    }
}

extension JumpEase {
    /// The far jump's curve, split as `split` splits it, for Core Animation: its leaving's and arriving's halves.
    struct Timings {
        var leave: CAMediaTimingFunction?
        var leaveFor = 0.0
        var arrive: CAMediaTimingFunction?
        var arriveFor = 0.0
    }

    static func timings(leaving out: Double, arriving in_: Double, over total: Double) -> Timings {
        func f(_ c: (Double, Double, Double, Double)) -> CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
        }
        let whole = f((curve.x1, curve.y1, curve.x2, curve.y2))
        guard out + in_ >= 1 else { return Timings() }
        if out < 1 { return Timings(arrive: whole, arriveFor: total) }
        if in_ < 1 { return Timings(leave: whole, leaveFor: total) }
        let (left, right, at) = cut(where: out / (out + in_))
        return Timings(leave: f(left), leaveFor: total * at, arrive: f(right), arriveFor: total * (1 - at))
    }
}
