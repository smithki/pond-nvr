// A card in the AppKit Events grid (`EventGridAppKit`): drawn as `EventCard` is, in layers, so the grid can move, fade
// and recycle hundreds of them without SwiftUI working out each one's views again. Looks the same as `EventCard`
// (compare the two with the snapshot step `cards`); what's done on clicking it is the grid's.
import AppKit
import SwiftUI

final class GridCardView: NSView {
    /// What it shows.
    struct Face: Equatable {
        var event: TimelineEvent
        var camera: String
        var dated = false
        var isNew = false
        var fresh = false
        var selected = false
        var outlined = false
        var width: Double
        var height: Double
    }

    private(set) var face: Face?
    var hovering = false { didSet { if hovering != oldValue { lit(animated: true) } } }

    private let background = CALayer()
    private let wash = CALayer()
    private let picture = CALayer()
    private let placeholder = CALayer()
    private let placeholderSymbol = CALayer()
    private let box = CAShapeLayer()
    private let badge = CALayer()
    private let badgeSymbol = CALayer()
    private let liveDot = CALayer()
    private let liveRing = CALayer()
    private let glow = CAShapeLayer()
    private let glowOuter = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let summary = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    private let dot = CALayer()
    /// Scrolling fast: a plain block where the card goes, the card itself faded away (`EventGrid.card`).
    private let block = CALayer()
    private(set) var blocked = false
    /// The picture being read for it, if it wasn't kept.
    private var reading: Task<Void, Never>?
    /// Fetches another Pond's picture (whether it came).
    var fetch: ((TimelineEvent) async -> Bool)?

    static let corner = 14.0, pictureCorner = 9.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.masksToBounds = false
        for l in [background, wash] {
            l.cornerRadius = Self.corner
            l.cornerCurve = .continuous
            layer.addSublayer(l)
        }
        picture.cornerRadius = Self.pictureCorner
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        layer.addSublayer(picture)
        placeholder.addSublayer(placeholderSymbol)
        placeholderSymbol.contentsGravity = .center
        picture.addSublayer(placeholder)
        box.fillColor = nil
        box.lineWidth = 2
        picture.addSublayer(box)
        badge.addSublayer(badgeSymbol)
        badgeSymbol.contentsGravity = .resizeAspect
        liveDot.cornerRadius = 4
        liveRing.cornerRadius = 4
        liveRing.borderWidth = 1.5
        badge.addSublayer(liveRing)
        badge.addSublayer(liveDot)
        picture.addSublayer(badge)
        for t in [summary, info] {
            t.isEditable = false
            t.isSelectable = false
            t.drawsBackground = false
            t.isBordered = false
            t.lineBreakMode = .byTruncatingTail
            addSubview(t)
        }
        summary.font = .preferredFont(forTextStyle: .callout)
        summary.maximumNumberOfLines = 2
        summary.cell?.truncatesLastVisibleLine = true
        summary.cell?.wraps = true
        info.font = .preferredFont(forTextStyle: .caption1)
        info.maximumNumberOfLines = 1
        info.textColor = .secondaryLabelColor
        dot.cornerRadius = 4
        layer.addSublayer(dot)
        for g in [glowOuter, glow] {
            g.fillColor = nil
            g.lineWidth = 3
            g.opacity = 0
            g.shadowOffset = .zero
            layer.addSublayer(g)
        }
        outline.fillColor = nil
        outline.lineWidth = 2
        outline.opacity = 0
        layer.addSublayer(outline)
        block.cornerRadius = Self.corner
        block.cornerCurve = .continuous
        block.opacity = 0
        layer.addSublayer(block)
        // (Every layer here moves and changes only when told: no implicit animations.)
        for l in [background, wash, picture, placeholder, placeholderSymbol, box, badge, badgeSymbol, liveDot, liveRing,
                  glow, glowOuter, outline, dot, block] {
            l.actions = Self.still
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let still: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
                                                "opacity": NSNull(), "backgroundColor": NSNull(), "path": NSNull(),
                                                "transform": NSNull(), "hidden": NSNull(), "strokeColor": NSNull(),
                                                "borderColor": NSNull(), "shadowRadius": NSNull(), "shadowOpacity": NSNull(),
                                                "cornerRadius": NSNull(), "sublayers": NSNull(), "shadowColor": NSNull()]

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    // MARK: What it shows

    /// Shown as `face`, changing only what's changed (`animated`: its washes, dot, glow and outline fading as
    /// `EventCard`'s do).
    func show(_ face: Face, animated: Bool) {
        let was = self.face
        self.face = face
        if was?.event != face.event || was?.width != face.width || was?.height != face.height || was?.dated != face.dated
            || was?.camera != face.camera {
            lay(face)
        }
        if was?.event.snapshot != face.event.snapshot || was?.event.id != face.event.id { showPicture(face.event) }
        let animate = animated && was?.event.id == face.event.id
        if was?.isNew != face.isNew || !animate { unseen(animate: animate) }
        if was?.fresh != face.fresh || !animate { glowing(animate: animate) }
        if was?.outlined != face.outlined || was?.selected != face.selected || !animate { outlining(animate: animate) }
        if was?.selected != face.selected || !animate { lit(animated: animate) }
    }

    /// Placed and sized, its words set (`EventCard`'s measures: its padding, the picture 16:9, its words below).
    private func lay(_ face: Face) {
        let event = face.event
        let w = face.width, h = face.height, pad = EventGridLayout.pad
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        background.frame = bounds
        wash.frame = bounds
        block.frame = bounds
        outline.path = Self.continuous(bounds, radius: Self.corner)
        outline.frame = bounds
        let pw = max(0, w - 2 * pad), ph = pw * 9 / 16
        picture.frame = CGRect(x: pad, y: pad, width: pw, height: ph)
        placeholder.frame = picture.bounds
        placeholderSymbol.frame = picture.bounds
        // The glow: inside the card's edge (a border's), its kind's colour.
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        for g in [glow, glowOuter] {
            g.frame = bounds
            g.path = Self.continuous(inset, radius: Self.corner - 1.5)
        }
        // The kind's badge, top right: a circle round its symbol (with the live dot, a capsule).
        let symbol = 13.0
        let bw = event.ongoing ? symbol + 5 + 8 + 16 : symbol + 10
        let bh = event.ongoing ? symbol + 8 : symbol + 10
        badge.frame = CGRect(x: pw - 6 - bw, y: 6, width: bw, height: bh)
        badge.cornerRadius = bh / 2
        badgeSymbol.frame = CGRect(x: event.ongoing ? 8 : 5, y: (bh - symbol) / 2, width: symbol, height: symbol)
        liveDot.isHidden = !event.ongoing
        liveRing.isHidden = !event.ongoing
        liveDot.frame = CGRect(x: 8 + symbol + 5, y: (bh - 8) / 2, width: 8, height: 8)
        liveRing.frame = liveDot.frame
        // Its words: the sentence (two lines' room kept), the line under it.
        // (A text field draws its words 2 pt in from its frame: placed that much further left, they sit where
        // SwiftUI's do.)
        let textX = pad + 4 - 2, textW = max(0, w - 2 * pad - 8) + 4
        let top = pad + ph + pad
        summary.stringValue = event.summary
        summary.preferredMaxLayoutWidth = textW
        let line = Self.lineHeight(summary.font!)
        summary.frame = CGRect(x: textX, y: top, width: textW, height: ceil(line * 2))
        let when = face.dated ? event.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                              : event.start.formatted(date: .omitted, time: .shortened)
        info.stringValue = "\(face.camera) \u{00B7} \(when) \u{00B7} \(event.quieted?.words ?? EventCallout.length(event.seconds))"
        let infoLine = ceil(Self.lineHeight(info.font!))
        info.frame = CGRect(x: textX, y: top + ceil(line * 2) + 3, width: max(0, textW - 16), height: infoLine)
        dot.frame = CGRect(x: textX + textW - 2 - 8, y: info.frame.midY - 4, width: 8, height: 8)
        CATransaction.commit()
        box.isHidden = event.box == nil
        colour()
        setAccessibilityLabel("\(event.summary), \(info.stringValue)")
        toolTip = event.pond == nil ? "Click for details, double-click to watch on the timeline" : "Click for details and its clip"
    }

    /// Its colours, for the appearance it's in (light or dark; a layer's colour doesn't follow it of itself).
    private func colour() {
        guard let face else { return }
        let kind = NSColor(face.event.kind.color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            placeholder.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            placeholderSymbol.contents = Self.symbol(face.event.kind.symbol, style: .largeTitle, weight: .regular,
                                                      colour: .tertiaryLabelColor)
            box.strokeColor = kind.cgColor
            badge.backgroundColor = kind.withAlphaComponent(0.85).cgColor
            badgeSymbol.contents = Self.symbol(face.event.kind.symbol, style: .caption1, weight: .semibold, colour: .white)
            liveDot.backgroundColor = NSColor.white.cgColor
            liveRing.borderColor = NSColor.white.cgColor
            for g in [glow, glowOuter] {
                g.strokeColor = kind.cgColor
                g.shadowColor = kind.cgColor
            }
            glow.shadowRadius = 12
            glowOuter.shadowRadius = 24
            outline.strokeColor = NSColor.controlAccentColor.cgColor
            dot.backgroundColor = NSColor.controlAccentColor.cgColor
            block.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(NSColor.quaternaryLabelColor.alphaComponent * 0.5).cgColor
            CATransaction.commit()
            summary.textColor = .labelColor
            lit(animated: false)
        }
        boxPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colour()
    }

    /// Its background: stronger hovered or chosen.
    private func lit(animated: Bool) {
        guard let face else { return }
        let alpha = (hovering || face.selected) ? 0.9 : 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colour = NSColor.quaternaryLabelColor.withAlphaComponent(NSColor.quaternaryLabelColor.alphaComponent * alpha).cgColor
            Self.change(background, "backgroundColor", to: colour, animated: animated, duration: 0.15)
        }
    }

    private func unseen(animate: Bool) {
        guard let face else { return }
        Self.change(wash, "opacity", to: face.isNew ? 1 : 0, animated: animate, duration: 0.3)
        Self.change(dot, "opacity", to: face.isNew ? 1 : 0, animated: animate, duration: 0.3)
        Self.change(dot, "transform", to: face.isNew ? CATransform3DIdentity : CATransform3DMakeScale(0.4, 0.4, 1),
                    animated: animate, duration: 0.3)
    }

    /// The glow round one just come in (`NewEventGlow`): up with a spring, a moment after it lands; away slowly.
    private func glowing(animate: Bool) {
        guard let face else { return }
        let on = face.fresh
        for (g, shadow) in [(glow, Float(0.9)), (glowOuter, Float(0.5))] {
            if animate && on {
                let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.35)
                spring.keyPath = "opacity"
                spring.fromValue = g.presentation()?.opacity ?? g.opacity
                spring.toValue = 1
                spring.beginTime = CACurrentMediaTime() + 0.35
                spring.fillMode = .backwards
                spring.duration = spring.settlingDuration
                g.add(spring, forKey: "opacity")
                g.opacity = 1
                g.shadowOpacity = shadow
            } else {
                Self.change(g, "opacity", to: on ? 1 : 0, animated: animate, duration: 0.8)
                g.shadowOpacity = shadow
            }
        }
    }

    /// The chosen card's outline (the grid's, in `EventGrid`): on while it's chosen, fading as the panel closes.
    private func outlining(animate: Bool) {
        guard let face else { return }
        Self.change(outline, "opacity", to: face.outlined && face.selected ? 1 : 0, animated: animate, duration: 0.4)
    }

    /// A plain block in its place (scrolling fast), or itself again; crossfading.
    func setBlocked(_ on: Bool, animated: Bool) {
        guard on != blocked || !animated else { return }
        blocked = on
        let duration = on ? 0.15 : 0.2
        Self.change(block, "opacity", to: on ? 1 : 0, animated: animated, duration: duration)
        let content: Float = on ? 0 : 1
        Self.change(picture, "opacity", to: content, animated: animated, duration: duration)
        Self.change(background, "opacity", to: content, animated: animated, duration: duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? duration : 0
            summary.animator().alphaValue = CGFloat(content)
            info.animator().alphaValue = CGFloat(content)
        }
        if !on { unseen(animate: animated) } else {
            Self.change(wash, "opacity", to: 0, animated: animated, duration: duration)
            Self.change(dot, "opacity", to: 0, animated: animated, duration: duration)
        }
    }

    // MARK: Its picture

    private func showPicture(_ event: TimelineEvent) {
        reading?.cancel()
        let image = event.snapshot.flatMap(EventPictures.kept)
        set(image)
        guard image == nil, let url = event.snapshot else { return }
        let id = event.id
        reading = Task { [weak self] in
            // (Another Pond's: fetched as it's first shown.)
            if event.pond != nil, await self?.fetch?(event) != true { return }
            let loaded = await EventPictures.load(url)
            guard !Task.isCancelled, let self, self.face?.event.id == id, let loaded else { return }
            self.set(loaded)
        }
    }

    private var image: NSImage?

    private func set(_ image: NSImage?) {
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        placeholder.isHidden = image != nil
        CATransaction.commit()
        boxPath()
    }

    /// The subject's box, on the picture as it fills the frame (centred, the overflow cropped).
    private func boxPath() {
        guard let face, let b = face.event.box else { return }
        let aspect = CameraAspect.known(face.event.camera) ?? 16.0 / 9.0
        let own = image.map { $0.size.height > 0 ? Double($0.size.width / $0.size.height) : aspect } ?? aspect
        let w = picture.bounds.width, h = picture.bounds.height
        guard w > 0, h > 0 else { return }
        let fill = own > w / h ? CGSize(width: h * own, height: h) : CGSize(width: w, height: w / own)
        let dx = (w - fill.width) / 2, dy = (h - fill.height) / 2
        let rect = CGRect(x: dx + b.x * fill.width, y: dy + b.y * fill.height, width: b.width * fill.width, height: b.height * fill.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.frame = picture.bounds
        box.path = RoundedRectangle(cornerRadius: 3).path(in: rect).cgPath
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // (The live dot's pulse: begun once it's shown.)
        if face?.event.ongoing == true, liveRing.animation(forKey: "pulse") == nil { pulse() }
    }

    private func pulse() {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = 1.2
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        both.repeatCount = .infinity
        liveRing.add(both, forKey: "pulse")
    }

    // MARK: Helpers

    static func change(_ layer: CALayer, _ key: String, to value: Any, animated: Bool, duration: Double) {
        if animated {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            a.toValue = value
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
    }

    static func lineHeight(_ font: NSFont) -> Double {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    /// SwiftUI's own rounded rectangle (continuous corners, as `EventCard`'s are).
    static func continuous(_ rect: CGRect, radius: Double) -> CGPath {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    /// An SF Symbol, drawn for a layer: in the size of a text style, in one colour.
    static func symbol(_ name: String, style: NSFont.TextStyle, weight: NSFont.Weight, colour: NSColor) -> CGImage? {
        let config = NSImage.SymbolConfiguration(textStyle: style).applying(.init(paletteColors: [colour]))
            .applying(.init(pointSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var rect = CGRect(origin: .zero, size: image.size)
        rect.size.width *= scale
        rect.size.height *= scale
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
    }
}
