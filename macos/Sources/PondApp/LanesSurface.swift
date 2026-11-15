// The Timeline's lanes as an image moved by Core Animation (docs/timeline-lanes.md): drawn once (the same drawing as the
// `Canvas`, `TimelineLanes.drawLanes`) over the stretch in view and as much again either side, and moved as the view
// glides, zooms, follows playing, or is panned, as SwiftUI moved the view (its time range sprung). Drawn again only when
// what it shows changes, or, while something in it moves with the clock (today's recording growing, zoomed in; a kind of
// event fading; other Ponds' lanes waiting), 30 times a second as the `Canvas` was. The playhead, and the words placed
// by the view's edges, are layers of their own. (The ruler is SwiftUI's still: `RulerDrawing`.)
import AppKit
import Observation
import SwiftUI

/// A word in the lanes placed by the view's edges, as `drawLanes` places it: drawn by the surface as a layer of its own,
/// where it'd be in the view at each moment (the surface's drawing is wider than the view).
struct EdgeLabel {
    enum Rule {
        /// At the start of its stretch's part in view (a bar's "Private", "Not recorded"), inset by `inset` round the
        /// bar; there if it fits.
        case cling(Date, Date, inset: Double)
        /// Just before its line (a camera's "… added"), if there's room before it.
        case before(Date)
        /// Beside its line ("Recording starts"): before it if there's room, else after.
        case beside(Date)
    }

    let text: Text
    /// On a plate (as "Private" is, over its stripes).
    let plate: Bool
    let box: CGSize
    let y: Double
    let rule: Rule

    /// Its middle across, and whether it's shown, for a view of `start`, `length` (seconds) across `width`.
    func place(start: Double, length: Double, width: Double) -> (x: Double, shown: Bool) {
        func x(_ d: Date) -> Double { (d.timeIntervalSinceReferenceDate - start) / length * width }
        switch rule {
        case let .cling(from, to, inset):
            let x0 = TimelineLanes.snap(max(0, x(from))) + inset, x1 = TimelineLanes.snap(min(width, x(to))) - inset
            let room = max(3, x1 - x0)
            if plate { return (x0 + 6 + (box.width + 8) / 2, box.width + 16 < room) }
            return (x0 + 8 + box.width / 2, box.width + 16 < room)
        case let .before(line):
            let px = x(line), mid = px - box.width / 2 - 6
            return (mid, px >= 0 && px <= width && mid - box.width / 2 >= 2)
        case let .beside(line):
            let px = min(width, x(line))
            return (TimelineLanes.startLabelX(line: px, width: box.width), x(line) >= 0 && x(line) <= width)
        }
    }
}

final class EdgeLabels { var list: [EdgeLabel] = [] }

struct LanesSurface: NSViewRepresentable {
    /// The lanes as they are now (where the view ends up: on the surface, SwiftUI doesn't move them frame by frame).
    let lanes: TimelineLanes
    let part: LanesSurfaceView.Part

    func makeNSView(context: Context) -> LanesSurfaceView { LanesSurfaceView(part: part) }

    func updateNSView(_ view: LanesSurfaceView, context: Context) {
        let t = context.transaction
        view.update(lanes, animated: t.animation != nil && !t.disablesAnimations)
    }
}

final class LanesSurfaceView: NSView {
    /// The lanes, or the ruler over them: two surfaces, moved by the same code from the same changes, so the ruler's
    /// ticks and the playhead's knob on it move with the lanes and the playhead's line over them, together (the ruler
    /// moved by SwiftUI's own animation drifted from the lanes when a move was taken over by another).
    enum Part { case ruler, lanes }
    let part: Part
    /// The drawing, and the playhead over it.
    private let content = CALayer()
    private let head = CALayer()
    /// The playhead's knob, at the ruler's top.
    private let knob = CALayer()
    /// The words placed by the view's edges (`EdgeLabel`), each a layer, over the drawing.
    private let words = CALayer()
    /// A zoom being drawn frame by frame: from and to where, since when.
    private var zoom: (from: (start: Double, length: Double), began: CFTimeInterval)?
    private var zoomLink: CADisplayLink?
    /// Where the zoom under way was going (for one begun over it).
    private var zoomTo: (start: Double, length: Double)?
    private var labels: [(label: EdgeLabel, layer: CALayer)] = []

    private var lanes: TimelineLanes?
    /// The playhead's time and the view's as last drawn (for its move from there).
    private var headWas: (time: Double, start: Double, length: Double)?
    /// Where the view is (its start and length, seconds since the reference date), as last told.
    private var start = 0.0, length = 0.0
    /// What's drawn: its stretch, at which length and size, with what it was given.
    private struct Drawn: Equatable {
        var from: Double, to: Double
        var length: Double
        var size: CGSize
        var given: Given
        /// The image's own size, in pixels.
        var pixels: CGSize
    }

    /// What a drawing is made with, besides the model (whose changes are watched while it's drawn).
    struct Given: Equatable {
        var cameras: [String]
        var folded: Set<String>
        var highlighted: String?
        var highlightedGroup: Set<String>
        var clock: Date
        var appearance: String
        /// The accent colour it's drawn in (the Mac's, changed in System Settings, draws it again).
        var accent: String
    }

    private var drawn: Drawn?
    /// The move under way (a glide): from where, to where, since when; so one begun over it starts from where the view's
    /// drawn now, not where the last was going (playing, the view follows the playhead with a glide five times a second).
    private var gliding: (from: (start: Double, length: Double), to: (start: Double, length: Double), began: CFTimeInterval)?
    /// The playhead's move under way, the same way.
    private var headGliding: (from: (time: Double, start: Double, length: Double), to: (time: Double, start: Double, length: Double),
                              began: CFTimeInterval)?
    /// Drawing with the clock (`TimelineLanes.animating`), 30 times a second, while nothing moves.
    private var ticking: Timer?
    private var widening: UUID?
    /// The model changed what was drawn: drawn again (at rest).
    private var stale = false
    private var moving: UUID?


    init(part: Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.anchorPoint = .zero
        content.contentsGravity = .resize
        layer?.addSublayer(content)
        words.anchorPoint = .zero
        layer?.addSublayer(words)
        head.backgroundColor = NSColor.systemRed.cgColor
        head.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(head)
        if part == .ruler {
            // (As `drawRuler` drew it: a dot 8 points across at the top, the line from 4 points down.)
            knob.backgroundColor = NSColor.systemRed.cgColor
            knob.cornerRadius = 4
            knob.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            knob.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(knob)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    // (The lanes' SwiftUI over it takes the pointer: hover, scrubbing.)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let lanes else { return }
        update(lanes, animated: false)
    }

    // (Off the window, its clocks stopped: drawing with the clock, a zoom.)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        tick(false)
        endZoom()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let lanes else { return }
        update(lanes, animated: false)
    }

    // MARK: Told where the view is

    func update(_ new: TimelineLanes, animated: Bool) {
        lanes = new
        let size = bounds.size
        guard size.width > 0, size.height > 0, new.length > 0 else { return }
        let last = (start: start, length: length)
        start = new.start
        length = new.length
        let changed = abs(last.start - start) > 1e-9 || abs(last.length - length) > 1e-9
        // From where it's drawn now (partway through a move, if one's under way).
        let was = changed ? presented(last) : last
        let given = given(new)
        // (Something drawn to move from: between the frames drawn with the clock, there's no wide drawing kept, and a
        // zoom out from 15 minutes on today, needing one, jumped.)
        let glide = animated && content.contents != nil && was.length > 0 && !(window?.inLiveResize ?? false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A zoom being drawn, and this no new move: it carries on to where the view is now.
        if zoom != nil, abs(was.length - length) < 1e-6, !(glide && new.animating) {
            placeHead(new, animated: glide)
            CATransaction.commit()
            tick(new.animating)
            return
        }
        // Moved without an animation (a pan's step, the window resized): what was moving stops where it's going, as
        // SwiftUI's did.
        if changed, !glide { stopMoves() }
        // (Gliding, what's drawn must reach from where the view was to where it goes.)
        let reach = glide ? (min(start, was.start), max(start + length, was.start + was.length)) : (start, start + length)
        // A glide further than the drawing reaches (a few views): drawn frame by frame, as a zoom.
        let far = glide && reach.1 - reach.0 > 5 * length
        if let drawn, drawn.length == length, drawn.size.height == size.height, drawn.given == given, !stale,
           drawn.from <= reach.0, reach.1 <= drawn.to, abs(drawn.size.width - size.width) < 0.5 {
            // Still within what's drawn: slid there.
            place(animated: glide, from: was)
        } else {
            // (So is a glide while the lanes move with the clock: they're being drawn every frame already.)
            if glide, abs(was.length - length) > 1e-6 || new.animating || far {
                // A zoom: drawn frame by frame at each moment's stretch, as the `Canvas` was (a picture scaled from
                // one length to another isn't the drawing at the lengths between: its marks stretched, its words with
                // them), for as long as it moves; then drawn as usual where it ends.
                beginZoom(from: was)
            } else if !glide {
                // Nothing to slide: the view's stretch alone, now (cheap, as the `Canvas` drew it), and the wide drawing
                // a moment later, once it's still (a new day, opened; an event outlined as the pointer passes over it;
                // what moves with the clock, 30 times a second).
                endZoom()
                drawFrame(start: start, length: length)
                widenLater()
            } else {
                endZoom()
                draw(given: given, size: size, keeping: glide ? was : nil)
                place(animated: glide, from: was)
            }
        }
        placeHead(new, animated: glide)
        CATransaction.commit()
        tick(new.animating)
    }

    /// Where the view's drawn now: partway through a move under way, else where it was last placed.
    private func presented(_ last: (start: Double, length: Double)) -> (start: Double, length: Double) {
        if let zoom, let to = zoomTo {
            let p = Self.progress(CACurrentMediaTime() - zoom.began)
            return (zoom.from.start + (to.start - zoom.from.start) * p, zoom.from.length + (to.length - zoom.from.length) * p)
        }
        guard let g = gliding else { return last }
        let t = CACurrentMediaTime() - g.began
        guard t < Self.springLength else { return last }
        let p = Self.progress(t)
        return (g.from.start + (g.to.start - g.from.start) * p, g.from.length + (g.to.length - g.from.length) * p)
    }

    /// While something in the lanes moves with the clock, drawn again 30 times a second (the view's stretch alone, as
    /// the `Canvas` drew it), unless the view's moving (then the move's drawing is slid, and drawn again after).
    private func tick(_ on: Bool) {
        if on, ticking == nil {
            ticking = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let lanes = self.lanes, self.window != nil else { return }
                    guard self.content.animation(forKey: "move") == nil else { return }
                    guard self.zoom == nil else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    if lanes.animating {
                        // (The view's stretch, its words in it, as the `Canvas` drew it.)
                        self.drawFrame(start: self.start, length: self.length)
                    } else {
                        // Done: the wide drawing again, to move.
                        self.draw(given: self.given(lanes), size: self.bounds.size, keeping: nil)
                        self.place(animated: false, from: (self.start, self.length))
                        self.tick(false)
                    }
                    CATransaction.commit()
                }
            }
        } else if !on, let timer = ticking {
            timer.invalidate()
            ticking = nil
        }
    }

    private func given(_ new: TimelineLanes) -> Given {
        // (The clock as far as it shows: the present's edge moved half a pixel. Each second, at a day's length, it was
        // drawn again for a hundredth of a pixel, a stutter every second while today was in view.)
        let step = max(1, new.length / max(bounds.width, 1) / 2)
        let clock = new.timeline.isToday
            ? Date(timeIntervalSinceReferenceDate: (new.clockNow.timeIntervalSinceReferenceDate / step).rounded(.down) * step) : .distantPast
        return Given(cameras: new.cameras.map(\.id), folded: new.folded, highlighted: new.highlighted,
              highlightedGroup: new.highlightedGroup, clock: clock,
              appearance: effectiveAppearance.name.rawValue, accent: "\(TimelineLanes.accent)\(NSColor.controlAccentColor)")
    }

    /// The drawing where the view's start puts it; moved there from where the view was, on the view's curve.
    private func place(animated: Bool, from was: (start: Double, length: Double)) {
        guard let drawn else { return }
        let width = bounds.width
        // (On whole pixels, at the drawing's own size: placed between pixels, or scaled a hair, it was softened.)
        let scale = window?.backingScaleFactor ?? 2
        let x = ((drawn.from - start) / length * width * scale).rounded() / scale
        let frame = CGRect(x: x, y: 0, width: drawn.pixels.width / scale, height: drawn.pixels.height / scale)
        content.frame = frame
        words.frame = bounds
        for (label, layer) in labels {
            let at = label.place(start: start, length: length, width: width)
            layer.position = CGPoint(x: at.x, y: label.y)
            layer.opacity = at.shown ? 1 : 0
        }
        guard animated, was.length > 0, abs(was.length - length) > 1e-6 || abs(was.start - start) / length * width > 0.25 else { return }
        // The words where they'd be at each moment of the move (clinging to the view's edge, hidden without room).
        for (label, layer) in labels {
            var xs: [NSNumber] = [], alphas: [NSNumber] = []
            for p in Self.springTimes {
                let at = label.place(start: was.start + (start - was.start) * p, length: was.length + (length - was.length) * p,
                                     width: width)
                xs.append(NSNumber(value: at.x))
                alphas.append(NSNumber(value: at.shown ? 1 : 0))
            }
            layer.add(Self.keyframes("position.x", xs), forKey: "move")
            layer.add(Self.keyframes("opacity", alphas), forKey: "shown")
        }
        // As SwiftUI moved the view: its start and length sprung from where they were to where they go (a spring in
        // the view's time, not the picture's scale: a zoom of a day from 15 minutes, its scale sprung, was squeezed far
        // past where it ends up), drawn at each moment by scaling and sliding the drawing made for where it ends up.
        let final = (start: start, length: length)
        let transforms = Self.springTimes.map { p -> NSValue in
            let s = was.start + (final.start - was.start) * p, l = was.length + (final.length - was.length) * p
            // Where its times are drawn at that moment, as x' = a·x + b of where they're drawn at the end.
            let a = final.length / l
            let b = (final.start - s) / l * width
            // (About the layer's origin: x' = position + a·local + tx.)
            let tx = a * frame.minX + b - frame.minX
            return NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(tx, 0, 0), a, 1, 1))
        }
        content.add(Self.keyframes("transform", transforms), forKey: "move")
        gliding = (was, final, CACurrentMediaTime())
    }

    /// The moves under way stopped where they're going (the drawing, its words, the playhead).
    private func stopMoves() {
        content.removeAnimation(forKey: "move")
        for (_, layer) in labels {
            layer.removeAnimation(forKey: "move")
            layer.removeAnimation(forKey: "shown")
        }
        for layer in [head, knob] {
            layer.removeAnimation(forKey: "move")
            layer.removeAnimation(forKey: "shown")
        }
        gliding = nil
        headGliding = nil
    }

    /// A zoom from `was` to where the view is now: drawn at each frame's stretch till it's done.
    private func beginZoom(from was: (start: Double, length: Double)) {
        content.removeAnimation(forKey: "move")
        // (From where a zoom under way has got to, if one is.)
        var from = was
        if let zoom, let to = zoomTo {
            let p = Self.progress(CACurrentMediaTime() - zoom.began)
            from = (zoom.from.start + (to.start - zoom.from.start) * p, zoom.from.length + (to.length - zoom.from.length) * p)
        }
        zoom = (from, CACurrentMediaTime())
        zoomTo = (start, length)
        if zoomLink == nil {
            let link = displayLink(target: self, selector: #selector(zoomFrame))
            link.add(to: .main, forMode: .common)
            zoomLink = link
        }
        zoomFrame()
    }

    @objc private func zoomFrame() {
        guard let zoom, let lanes else { return endZoom() }
        let t = CACurrentMediaTime() - zoom.began
        guard t < Self.springLength else {
            endZoom()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            draw(given: given(lanes), size: bounds.size, keeping: nil)
            place(animated: false, from: (start, length))
            CATransaction.commit()
            return
        }
        let p = Self.progress(t)
        let s = zoom.from.start + (start - zoom.from.start) * p, l = zoom.from.length + (length - zoom.from.length) * p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawFrame(start: s, length: l)
        CATransaction.commit()
    }

    private func endZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
        zoom = nil
    }

    /// The view's stretch at `start`, `length`, drawn as the `Canvas` drew it (its words in it, by its edges).
    private func drawFrame(start s: Double, length l: Double) {
        guard let lanes, bounds.width > 0 else { return }
        var copy = lanes
        copy.hidesHead = true
        copy.start = s
        copy.length = l
        let size = bounds.size
        let visible = Date(timeIntervalSinceReferenceDate: s) ... Date(timeIntervalSinceReferenceDate: s + l)
        let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let part = self.part
        let renderer = ImageRenderer(content: Canvas { context, canvasSize in
            switch part {
            case .ruler: copy.drawRuler(context, size: canvasSize, visible: visible)
            case .lanes: copy.drawLanes(context, size: canvasSize, visible: visible, now: copy.clockNow, frame: Date())
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .tint(TimelineLanes.accent))
        renderer.scale = window?.backingScaleFactor ?? 2
        content.contents = renderer.cgImage
        content.contentsScale = renderer.scale
        content.transform = CATransform3DIdentity
        content.frame = bounds
        words.opacity = 0
        drawn = nil
    }

    /// The spring's progress at `t` seconds (`springTimes`' curve).
    static func progress(_ t: Double) -> Double {
        let duration = 0.35, bounce = 0.15
        let omega = 2 * Double.pi / duration, zeta = 1 - bounce
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }

    /// SwiftUI's `.snappy(duration: 0.35)` (a spring, bounce 0.15), sampled: its progress at each of its moments, from 0
    /// to (all but) 1, as long as it takes to settle.
    static let springTimes: [Double] = {
        let duration = 0.35, bounce = 0.15
        let omega = 2 * Double.pi / duration, zeta = 1 - bounce
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let n = Int(springLength * 120)
        return (0 ... n).map { i in
            let t = springLength * Double(i) / Double(n)
            return i == n ? 1 : 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
    }()
    /// Till it's within a thousandth of where it ends.
    static let springLength: Double = 6.9 / ((1 - 0.15) * 2 * Double.pi / 0.35)

    static func keyframes(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = values
        a.duration = springLength
        a.calculationMode = .linear
        a.fillMode = .backwards
        return a
    }

    private func placeHead(_ lanes: TimelineLanes, animated: Bool) {
        guard let time = lanes.headTime else {
            head.isHidden = true
            knob.opacity = 0
            return
        }
        let width = bounds.width
        func inView(_ x: Double) -> Bool { x >= -2 && x <= width + 2 }
        let x = (time.timeIntervalSinceReferenceDate - start) / length * width
        let target = (time: time.timeIntervalSinceReferenceDate, start: start, length: length)
        // From where it's drawn now (partway through its move, if one's under way).
        var from = headWas
        if let g = headGliding {
            let t = CACurrentMediaTime() - g.began
            if t < Self.springLength {
                let p = Self.progress(t)
                from = (g.from.time + (g.to.time - g.from.time) * p, g.from.start + (g.to.start - g.from.start) * p,
                        g.from.length + (g.to.length - g.from.length) * p)
            }
        }
        headWas = target
        let top: CGFloat = part == .ruler ? 4 : 0
        head.bounds = CGRect(x: 0, y: 0, width: 2, height: max(0, bounds.height - top))
        head.position = CGPoint(x: x, y: top)
        knob.position = CGPoint(x: x, y: 0)
        head.opacity = inView(x) ? 1 : 0
        knob.opacity = head.opacity
        head.isHidden = false
        guard animated, let from, from.length > 0,
              abs(from.time - target.time) > 1e-6 || abs(from.start - target.start) > 1e-6 || abs(from.length - target.length) > 1e-6
        else { return }
        // Its time, and the view's, sprung together (as SwiftUI did): where it's drawn at each moment; shown while it's
        // in view (on its way in or out of view, not hidden the whole way).
        var xs: [NSNumber] = [], alphas: [NSNumber] = []
        for p in Self.springTimes {
            let h = from.time + (target.time - from.time) * p
            let s = from.start + (target.start - from.start) * p, l = from.length + (target.length - from.length) * p
            let at = (h - s) / l * width
            xs.append(NSNumber(value: at))
            alphas.append(NSNumber(value: inView(at) ? 1 : 0))
        }
        for layer in [head, knob] {
            layer.add(Self.keyframes("position.x", xs), forKey: "move")
            layer.add(Self.keyframes("opacity", alphas), forKey: "shown")
        }
        headGliding = (from, target, CACurrentMediaTime())
    }

    // MARK: Drawn

    /// The drawing made again: the view's stretch, and its length again either side (and, gliding, wherever the view
    /// was, so the glide's whole way is drawn).
    /// The wide drawing, made once things are still (nothing moving with the clock, no move or zoom under way).
    private func widenLater() {
        let id = UUID()
        widening = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.widening == id, let lanes = self.lanes else { return }
            guard self.drawn == nil, self.zoom == nil, !lanes.animating, self.content.animation(forKey: "move") == nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.draw(given: self.given(lanes), size: self.bounds.size, keeping: nil)
            self.place(animated: false, from: (self.start, self.length))
            CATransaction.commit()
        }
    }

    private func draw(given: Given, size: CGSize, keeping was: (start: Double, length: Double)?) {
        guard let lanes else { return }
        var from = start - length, to = start + 2 * length
        if let was, was.length == length {
            from = min(from, was.start - length / 4)
            to = max(to, was.start + was.length + length / 4)
        }
        // (No wider than a few views: a far jump is crossfaded, not slid, by the lanes' own transition.)
        from = max(from, start - 4 * length)
        to = min(to, start + 5 * length)
        let width = (to - from) / length * size.width
        var copy = lanes
        copy.hidesHead = true
        let collected = EdgeLabels()
        copy.edgeLabels = collected
        copy.start = from
        copy.length = length
        let visible = Date(timeIntervalSinceReferenceDate: from) ... Date(timeIntervalSinceReferenceDate: to)
        let part = self.part
        let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let canvas = Canvas { context, canvasSize in
            switch part {
            case .ruler: copy.drawRuler(context, size: canvasSize, visible: visible)
            // (At the present, as the `Canvas` was: what's going on now ends there; a kind being faded, as far as it's
            // got; drawn again with the clock while those move.)
            case .lanes: copy.drawLanes(context, size: canvasSize, visible: visible, now: copy.clockNow, frame: Date())
            }
        }
        .frame(width: width, height: size.height)
        .environment(\.colorScheme, scheme)
        // (Drawn apart from the window, it'd have the system's blue, not the app's accent.)
        .tint(TimelineLanes.accent)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = window?.backingScaleFactor ?? 2
        // What the drawing read of the model changing (events, recordings), it's drawn again.
        let image = withObservationTracking { renderer.cgImage } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stale = true
                if let lanes = self.lanes { self.update(lanes, animated: false) }
            }
        }
        stale = false
        content.contents = image
        content.contentsScale = renderer.scale
        makeLabels(collected.list, scheme: scheme, scale: renderer.scale)
        words.opacity = 1
        drawn = Drawn(from: from, to: to, length: length, size: size, given: given,
                      pixels: CGSize(width: image?.width ?? 0, height: image?.height ?? 0))
    }

    /// The words' layers, made for what was collected (each a small image of its word, on its plate if it has one).
    private func makeLabels(_ list: [EdgeLabel], scheme: ColorScheme, scale: CGFloat) {
        for (_, layer) in labels { layer.removeFromSuperlayer() }
        labels = list.map { label in
            let view = Group {
                if label.plate {
                    label.text.frame(width: label.box.width + 8, height: label.box.height + 2)
                        .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    label.text.fixedSize()
                }
            }
            .environment(\.colorScheme, scheme)
            .tint(TimelineLanes.accent)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            let layer = CALayer()
            layer.contents = renderer.cgImage
            layer.contentsScale = scale
            let image = renderer.cgImage
            layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image?.width ?? 0) / scale, height: CGFloat(image?.height ?? 0) / scale)
            words.addSublayer(layer)
            return (label, layer)
        }
    }
}
