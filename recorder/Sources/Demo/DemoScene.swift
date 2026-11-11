// A demo camera's picture: a flat, drawn scene (a front door, a driveway, a lawn…) lit by the time of day, grey
// in infrared at night as cameras are, with what comes by drawn over it and the date and time burnt in at the top,
// as cameras do. The backdrop is drawn once for a light and a view and kept; each frame draws it, then the visitors.
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import PondCore

final class DemoPainter {
    let camera: Demo.Camera
    let world: DemoWorld
    let width: Int, height: Int
    /// The backdrop as last drawn, and for what.
    private var backdrop: (key: String, image: CGImage)?
    private let space = CGColorSpaceCreateDeviceRGB()

    init(camera: Demo.Camera, world: DemoWorld, width: Int, height: Int) {
        self.camera = camera
        self.world = world
        self.width = width
        self.height = height
    }

    /// The picture at `t`, into a BGRA pixel buffer of the painter's size.
    func paint(_ buffer: CVPixelBuffer, at t: Date) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        paint(context, at: t)
    }

    func paint(_ context: CGContext, at t: Date) {
        let view = world.view(camera.id, at: t)
        let light = world.light(camera.id, at: t)
        let palette = Palette(daylight: light.daylight, infrared: light.infrared, brightness: light.brightness)
        let key = String(format: "%.3f %.3f %.3f %.2f %d %.0f", view.x, view.y, view.width, light.daylight, light.infrared ? 1 : 0,
                         light.brightness)
        if backdrop?.key != key, let image = drawBackdrop(view: view, palette: palette) { backdrop = (key, image) }
        if let image = backdrop?.image { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        let canvas = Canvas(context: context, view: view, size: (Double(width), Double(height)), palette: palette)
        for figure in world.figures(camera.id, at: t) { canvas.draw(figure) }
        if light.infrared == false && light.daylight < 0.5 { canvas.headlights(world.figures(camera.id, at: t)) }
        overlay(context, at: world.drifted(camera.id, t))
    }

    private func drawBackdrop(view: (x: Double, y: Double, width: Double, height: Double), palette: Palette) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        Canvas(context: context, view: view, size: (Double(width), Double(height)), palette: palette).backdrop(camera.scene)
        return context.makeImage()
    }

    /// The date and time, top left; the camera's name, bottom right.
    private func overlay(_ context: CGContext, at t: Date) {
        let size = CGFloat(height) / 26
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd EEE HH:mm:ss"
        text(context, formatter.string(from: t), at: CGPoint(x: size * 0.8, y: CGFloat(height) - size * 1.6), size: size)
        let name = camera.name.uppercased()
        let line = CTLineCreateWithAttributedString(attributed(name, size: size))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        text(context, name, at: CGPoint(x: CGFloat(width) - CGFloat(w) - size * 0.8, y: size * 0.8), size: size)
    }

    private func attributed(_ string: String, size: CGFloat) -> CFAttributedString {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.92)]
        return CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)
    }

    private func text(_ context: CGContext, _ string: String, at point: CGPoint, size: CGFloat) {
        let line = CTLineCreateWithAttributedString(attributed(string, size: size))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 1, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.8))
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Colours under the scene's light: as they are by day, darker and bluer toward night, grey in infrared.
struct Palette {
    let daylight: Double
    let infrared: Bool
    let brightness: Double

    func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1, glows: Bool = false) -> CGColor {
        let gain = 0.65 + 0.7 * brightness / 100
        if infrared {
            let l = 0.3 * r + 0.59 * g + 0.11 * b
            let v = min(1, (l * 0.85 + 0.1) * gain)
            return CGColor(red: v, green: v, blue: v * 1.02, alpha: a)
        }
        if glows { return CGColor(red: r, green: g, blue: b, alpha: a) }
        let lit = 0.1 + 0.9 * daylight
        let blue = (1 - daylight) * 0.06
        return CGColor(red: min(1, r * lit * gain), green: min(1, g * lit * gain), blue: min(1, (b * lit + blue) * gain), alpha: a)
    }

    func hue(_ h: Double, saturation: Double = 0.55, value: Double = 0.75) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = value * (1 - saturation), q = value * (1 - f * saturation), t = value * (1 - (1 - f) * saturation)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (value, t, p)
        case 1: (q, value, p)
        case 2: (p, value, t)
        case 3: (p, q, value)
        case 4: (t, p, value)
        default: (value, p, q)
        }
        return color(r, g, b)
    }
}

/// Drawing in the scene's terms: x and y as fractions of the whole scene, from the top left, whatever part of it
/// the camera shows.
struct Canvas {
    let context: CGContext
    let view: (x: Double, y: Double, width: Double, height: Double)
    let size: (width: Double, height: Double)
    let palette: Palette

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (x - view.x) / view.width * size.width, y: size.height - (y - view.y) / view.height * size.height)
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        let a = point(x, y), b = point(x + w, y + h)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Scene units of height in pixels.
    func pixels(_ h: Double) -> CGFloat { CGFloat(h / view.height * size.height) }

    func fill(_ r: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        context.setFillColor(color)
        if radius > 0 {
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
            context.fillPath()
        } else {
            context.fill(r)
        }
    }

    func polygon(_ points: [(Double, Double)], _ color: CGColor) {
        guard let first = points.first else { return }
        context.setFillColor(color)
        context.move(to: point(first.0, first.1))
        for p in points.dropFirst() { context.addLine(to: point(p.0, p.1)) }
        context.closePath()
        context.fillPath()
    }

    /// A circle `radius` scene-heights across, its middle at (x, y).
    func circle(_ x: Double, _ y: Double, _ radius: Double, _ color: CGColor) {
        let c = point(x, y), r = pixels(radius)
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: rect(x, y, w, h))
    }

    func line(_ a: (Double, Double), _ b: (Double, Double), width: Double, _ color: CGColor) {
        context.setStrokeColor(color)
        context.setLineWidth(max(1, pixels(width)))
        context.setLineCap(.round)
        context.move(to: point(a.0, a.1))
        context.addLine(to: point(b.0, b.1))
        context.strokePath()
    }

    func gradient(_ top: Double, _ bottom: Double, _ a: CGColor, _ b: CGColor) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a, b] as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: rect(-1, top, 3, bottom - top))
        context.drawLinearGradient(g, start: point(0, top), end: point(0, bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    var c: Palette { palette }

    // MARK: Backdrops

    func backdrop(_ scene: Demo.Scene) {
        switch scene {
        case .frontDoor, .porch: frontDoor(lake: scene == .porch)
        case .driveway: driveway()
        case .backyard: backyard(shed: false)
        case .shed: backyard(shed: true)
        case .garage: garage()
        case .livingRoom: livingRoom()
        case .sideGate: sideGate()
        case .street: street()
        case .dock: dock()
        }
    }

    func sky(to horizon: Double) {
        let d = palette.daylight
        // Day blue; dusk warmer; night deep blue.
        let top = palette.infrared ? c.color(0.35, 0.35, 0.35) : c.color(0.32 + 0.1 * (1 - d), 0.55, 0.88, glows: false)
        let low = palette.infrared ? c.color(0.5, 0.5, 0.5) : c.color(0.75 + 0.2 * (1 - d) * d * 4, 0.82, 0.92)
        // On past the horizon, under whatever ground is drawn next (nothing left unpainted between).
        gradient(-0.2, horizon, top, low)
        fill(rect(-1, horizon - 0.001, 3, 0.2), low)
        if !palette.infrared, d < 0.3 {
            // Stars aren't drawn (they'd shimmer); a moon is.
            circle(0.82, 0.1, 0.035, c.color(0.95, 0.95, 0.85, glows: true))
        }
    }

    func ground(from horizon: Double, _ r: Double, _ g: Double, _ b: Double) {
        gradient(horizon, 1.2, c.color(r * 0.85, g * 0.85, b * 0.85), c.color(r, g, b))
    }

    func tree(_ x: Double, _ base: Double, _ h: Double, shade: Double = 0) {
        fill(rect(x - h * 0.05, base - h * 0.45, h * 0.1, h * 0.45), c.color(0.38, 0.27, 0.18))
        circle(x, base - h * 0.62, h * 0.3, c.color(0.2 + shade, 0.45 + shade, 0.22))
        circle(x - h * 0.16, base - h * 0.5, h * 0.22, c.color(0.17 + shade, 0.4 + shade, 0.2))
        circle(x + h * 0.17, base - h * 0.52, h * 0.22, c.color(0.22 + shade, 0.5 + shade, 0.25))
    }

    func house(_ x: Double, _ base: Double, _ w: Double, _ h: Double, wall: (Double, Double, Double), roof: (Double, Double, Double)) {
        fill(rect(x, base - h, w, h), c.color(wall.0, wall.1, wall.2))
        polygon([(x - w * 0.06, base - h), (x + w / 2, base - h * 1.55), (x + w * 1.06, base - h)], c.color(roof.0, roof.1, roof.2))
        for i in 0 ..< 3 {
            let wx = x + w * (0.12 + Double(i) * 0.3)
            let lit = palette.daylight < 0.4 && i != 1
            fill(rect(wx, base - h * 0.75, w * 0.16, h * 0.3), lit ? c.color(1, 0.85, 0.5, glows: true) : c.color(0.55, 0.68, 0.78))
        }
    }

    func road(_ top: Double, _ bottom: Double) {
        fill(rect(-1, top, 3, bottom - top), c.color(0.36, 0.37, 0.39))
        let y = (top + bottom) / 2
        var x = -0.95
        while x < 2 {
            fill(rect(x, y - (bottom - top) * 0.04, 0.06, (bottom - top) * 0.08), c.color(0.92, 0.88, 0.6))
            x += 0.14
        }
    }

    func fence(_ y: Double, _ h: Double, from: Double = -0.1, to: Double = 1.1) {
        var x = from
        while x < to {
            fill(rect(x, y - h, 0.03, h), c.color(0.72, 0.62, 0.48))
            x += 0.05
        }
        fill(rect(from, y - h * 0.8, to - from, h * 0.1), c.color(0.6, 0.5, 0.38))
        fill(rect(from, y - h * 0.35, to - from, h * 0.1), c.color(0.6, 0.5, 0.38))
    }

    func frontDoor(lake: Bool) {
        sky(to: 0.4)
        if lake {
            fill(rect(-1, 0.3, 3, 0.12), c.color(0.25, 0.45, 0.6))
            tree(0.1, 0.33, 0.25); tree(0.9, 0.32, 0.22, shade: 0.04)
        } else {
            house(0.62, 0.38, 0.3, 0.14, wall: (0.85, 0.82, 0.75), roof: (0.45, 0.3, 0.28))
            tree(0.12, 0.38, 0.3)
        }
        ground(from: 0.4, 0.42, 0.62, 0.32)
        road(0.4, 0.48)
        // The porch: boards, the path up to it, a door frame on the right.
        polygon([(0.28, 0.6), (0.72, 0.6), (1.0, 1.05), (0.0, 1.05)], c.color(0.62, 0.6, 0.56))
        polygon([(-0.2, 0.75), (1.2, 0.75), (1.2, 1.1), (-0.2, 1.1)], c.color(0.55, 0.45, 0.36))
        for i in 0 ..< 7 { fill(rect(-0.2, 0.78 + Double(i) * 0.045, 1.4, 0.004), c.color(0.45, 0.36, 0.29)) }
        fill(rect(0.88, 0.05, 0.14, 0.75), c.color(0.92, 0.9, 0.86))
        fill(rect(0.9, 0.1, 0.1, 0.65), lake ? c.color(0.35, 0.45, 0.4) : c.color(0.55, 0.15, 0.15))
        circle(0.92, 0.45, 0.012, c.color(0.85, 0.75, 0.3))
        if !lake { fill(rect(-0.02, 0.62, 0.16, 0.14), c.color(0.3, 0.5, 0.28), radius: 6) }
    }

    func driveway() {
        sky(to: 0.38)
        house(0.05, 0.38, 0.32, 0.16, wall: (0.78, 0.8, 0.84), roof: (0.3, 0.32, 0.36))
        tree(0.7, 0.38, 0.32, shade: 0.03)
        ground(from: 0.38, 0.4, 0.6, 0.3)
        road(0.38, 0.48)
        polygon([(0.3, 0.5), (0.75, 0.5), (1.3, 1.1), (0.05, 1.1)], c.color(0.7, 0.69, 0.66))
        fill(rect(-0.1, 0.5, 0.36, 0.6), c.color(0.38, 0.6, 0.3))
        fence(0.62, 0.1, from: -0.1, to: 0.25)
    }

    func backyard(shed: Bool) {
        sky(to: 0.35)
        tree(0.08, 0.37, 0.34); tree(0.32, 0.35, 0.26, shade: 0.05); tree(0.95, 0.36, 0.32, shade: 0.02)
        fence(0.42, 0.11)
        ground(from: 0.42, 0.38, 0.64, 0.3)
        if shed {
            fill(rect(0.55, 0.3, 0.28, 0.3), c.color(0.55, 0.4, 0.3))
            polygon([(0.53, 0.3), (0.69, 0.2), (0.85, 0.3)], c.color(0.3, 0.25, 0.22))
            fill(rect(0.64, 0.4, 0.1, 0.2), c.color(0.4, 0.3, 0.24))
        } else {
            fill(rect(0.58, 0.5, 0.3, 0.035), c.color(0.6, 0.45, 0.32))
            for x in [0.6, 0.85] { fill(rect(x, 0.535, 0.015, 0.06), c.color(0.5, 0.38, 0.28)) }
            ellipse(0.15, 0.6, 0.3, 0.08, c.color(0.5, 0.42, 0.34))
        }
    }

    func garage() {
        fill(rect(-1, -1, 3, 3), c.color(0.82, 0.8, 0.76))
        fill(rect(0.22, 0.08, 0.56, 0.5), c.color(0.92, 0.92, 0.9))
        for i in 0 ..< 6 { fill(rect(0.23, 0.1 + Double(i) * 0.08, 0.54, 0.006), c.color(0.75, 0.75, 0.73)) }
        polygon([(0.22, 0.58), (0.78, 0.58), (1.2, 1.1), (-0.2, 1.1)], c.color(0.62, 0.62, 0.6))
        fill(rect(0.02, 0.15, 0.12, 0.2), c.color(0.4, 0.5, 0.6))
        fill(rect(0.86, 0.12, 0.08, 0.46), c.color(0.6, 0.4, 0.3))
        fill(rect(0.84, 0.05, 0.12, 0.02), c.color(0.95, 0.95, 0.85, glows: true))
    }

    func livingRoom() {
        fill(rect(-1, -1, 3, 3), c.color(0.86, 0.82, 0.74))
        fill(rect(-1, 0.68, 3, 1), c.color(0.6, 0.45, 0.32))
        fill(rect(0.6, 0.12, 0.3, 0.32), c.color(0.6, 0.72, 0.85))
        fill(rect(0.745, 0.12, 0.01, 0.32), c.color(0.95, 0.95, 0.95))
        fill(rect(0.08, 0.45, 0.42, 0.18), c.color(0.3, 0.4, 0.55), radius: 10)
        fill(rect(0.06, 0.38, 0.46, 0.1), c.color(0.27, 0.36, 0.5), radius: 10)
        fill(rect(0.15, 0.7, 0.28, 0.04), c.color(0.45, 0.32, 0.22))
        circle(0.88, 0.62, 0.04, c.color(0.25, 0.5, 0.3))
        fill(rect(0.86, 0.64, 0.04, 0.06), c.color(0.7, 0.4, 0.3))
    }

    func sideGate() {
        sky(to: 0.25)
        ground(from: 0.3, 0.4, 0.6, 0.3)
        fill(rect(-0.2, 0.0, 0.35, 1.2), c.color(0.8, 0.78, 0.72))
        fill(rect(0.85, 0.0, 0.4, 1.2), c.color(0.6, 0.55, 0.5))
        polygon([(0.3, 0.3), (0.7, 0.3), (1.0, 1.1), (0.05, 1.1)], c.color(0.62, 0.6, 0.55))
        tree(0.5, 0.3, 0.25)
        fill(rect(0.38, 0.12, 0.26, 0.2), c.color(0.5, 0.4, 0.3))
        for i in 0 ..< 6 { fill(rect(0.39 + Double(i) * 0.042, 0.12, 0.012, 0.2), c.color(0.4, 0.3, 0.22)) }
    }

    func street() {
        sky(to: 0.35)
        house(0.02, 0.4, 0.28, 0.14, wall: (0.8, 0.72, 0.62), roof: (0.4, 0.26, 0.22))
        house(0.42, 0.4, 0.24, 0.12, wall: (0.7, 0.78, 0.82), roof: (0.25, 0.3, 0.35))
        tree(0.82, 0.4, 0.3)
        ground(from: 0.4, 0.4, 0.6, 0.3)
        fill(rect(-1, 0.48, 3, 0.06), c.color(0.75, 0.74, 0.7))
        road(0.54, 0.76)
        fill(rect(-1, 0.76, 3, 0.12), c.color(0.75, 0.74, 0.7))
    }

    func dock() {
        sky(to: 0.36)
        fill(rect(-1, 0.3, 3, 0.08), c.color(0.25, 0.35, 0.3))
        tree(0.2, 0.33, 0.2); tree(0.65, 0.32, 0.18, shade: 0.04)
        gradient(0.36, 0.7, c.color(0.3, 0.5, 0.65), c.color(0.2, 0.38, 0.52))
        for i in 0 ..< 5 { fill(rect(0.1 + Double(i) * 0.17, 0.45 + Double(i % 2) * 0.08, 0.1, 0.004), c.color(0.6, 0.75, 0.85)) }
        ground(from: 0.62, 0.36, 0.55, 0.3)
        polygon([(0.45, 0.5), (0.65, 0.5), (0.75, 1.1), (0.3, 1.1)], c.color(0.62, 0.5, 0.38))
        for i in 0 ..< 10 { fill(rect(0.3, 0.52 + Double(i) * 0.06, 0.5, 0.004), c.color(0.5, 0.4, 0.3)) }
        fill(rect(0.06, 0.68, 0.18, 0.05), c.color(0.75, 0.25, 0.2), radius: 8)
    }

    // MARK: Visitors

    func draw(_ f: Figure) {
        guard let visitor = f.visitor else { return box(f.x, f.y, f.width, f.height) }
        switch visitor {
        case .person, .courier: person(f, courier: visitor == .courier)
        case .cyclist: cyclist(f)
        case .car: car(f)
        case .cat, .dog, .deer: animal(f, visitor)
        }
    }

    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        fill(rect(x, y, w, h), c.color(0.72, 0.55, 0.35), radius: 2)
        fill(rect(x, y + h * 0.4, w, h * 0.12), c.color(0.85, 0.8, 0.65))
    }

    func person(_ f: Figure, courier: Bool) {
        let h = f.height, cx = f.x + f.width / 2, foot = f.y + h
        let swing = f.moving ? sin(f.phase * 7) * h * 0.08 : 0
        let shirt = courier ? c.color(0.45, 0.33, 0.2) : palette.hue(f.hue)
        let trousers = courier ? c.color(0.4, 0.3, 0.2) : c.color(0.22, 0.24, 0.32)
        // Legs, then the body, arms, head.
        line((cx, foot - h * 0.45), (cx - swing, foot), width: h * 0.075, trousers)
        line((cx, foot - h * 0.45), (cx + swing, foot), width: h * 0.075, trousers)
        fill(rect(cx - h * 0.1, f.y + h * 0.2, h * 0.2, h * 0.32), shirt, radius: pixels(h * 0.05))
        line((cx, f.y + h * 0.24), (cx + swing, f.y + h * 0.48), width: h * 0.055, shirt)
        circle(cx, f.y + h * 0.11, h * 0.085, c.color(0.85, 0.68, 0.55))
        fill(rect(cx - h * 0.085, f.y + h * 0.02, h * 0.17, h * 0.06), courier ? c.color(0.4, 0.3, 0.18) : c.color(0.25, 0.18, 0.12), radius: 3)
        if f.carrying { box(cx + (f.leftward ? -h * 0.22 : h * 0.02), f.y + h * 0.3, h * 0.2, h * 0.16) }
    }

    func cyclist(_ f: Figure) {
        let h = f.height, r = h * 0.2, foot = f.y + h
        let back = f.x + r * 1.1, front = f.x + f.width - r * 1.1
        for x in [back, front] {
            context.setStrokeColor(c.color(0.15, 0.15, 0.15))
            context.setLineWidth(max(1, pixels(h * 0.03)))
            let p = point(x, foot - r), radius = pixels(r)
            context.strokeEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        }
        line((back, foot - r), (front, foot - r), width: h * 0.03, palette.hue(f.hue, saturation: 0.7))
        let seat = (f.x + f.width * 0.42, foot - h * 0.5)
        line((seat.0, seat.1), (f.x + f.width * 0.5, foot - r), width: h * 0.06, c.color(0.2, 0.22, 0.3))
        fill(rect(seat.0 - h * 0.08, f.y + h * 0.18, h * 0.16, h * 0.3), palette.hue(f.hue + 0.4), radius: 4)
        circle(seat.0 + h * 0.05, f.y + h * 0.1, h * 0.08, c.color(0.85, 0.68, 0.55))
    }

    func car(_ f: Figure) {
        let h = f.height, w = f.width, foot = f.y + h
        let body = palette.hue(f.hue, saturation: 0.45, value: 0.7)
        polygon([(f.x + w * 0.2, f.y + h * 0.42), (f.x + w * 0.32, f.y), (f.x + w * 0.7, f.y), (f.x + w * 0.82, f.y + h * 0.42)], body)
        fill(rect(f.x, f.y + h * 0.38, w, h * 0.42), body, radius: pixels(h * 0.12))
        polygon([(f.x + w * 0.26, f.y + h * 0.4), (f.x + w * 0.35, f.y + h * 0.08), (f.x + w * 0.49, f.y + h * 0.08),
                 (f.x + w * 0.49, f.y + h * 0.4)], c.color(0.5, 0.62, 0.72))
        polygon([(f.x + w * 0.52, f.y + h * 0.4), (f.x + w * 0.52, f.y + h * 0.08), (f.x + w * 0.67, f.y + h * 0.08),
                 (f.x + w * 0.76, f.y + h * 0.4)], c.color(0.5, 0.62, 0.72))
        for x in [f.x + w * 0.2, f.x + w * 0.8] {
            circle(x, foot - h * 0.17, h * 0.17, c.color(0.12, 0.12, 0.12))
            circle(x, foot - h * 0.17, h * 0.07, c.color(0.6, 0.6, 0.6))
        }
        let lamp = f.leftward ? f.x + w * 0.01 : f.x + w * 0.95
        fill(rect(lamp, f.y + h * 0.48, w * 0.04, h * 0.1), c.color(1, 0.95, 0.75, glows: palette.daylight < 0.5))
    }

    func animal(_ f: Figure, _ kind: Visitor) {
        let h = f.height, w = f.width
        let coat: CGColor = switch kind {
        case .cat: f.hue < 0.5 ? c.color(0.3, 0.28, 0.27) : c.color(0.85, 0.55, 0.3)
        case .dog: c.color(0.65, 0.5, 0.3)
        default: c.color(0.55, 0.4, 0.28)
        }
        let swing = f.moving ? sin(f.phase * 9) * w * 0.05 : 0
        let headX = f.leftward ? f.x + w * 0.1 : f.x + w * 0.9
        let legTop = f.y + h * 0.6, foot = f.y + h
        for (i, x) in [0.22, 0.32, 0.68, 0.78].enumerated() {
            let lx = f.x + w * x
            line((lx, legTop), (lx + (i % 2 == 0 ? swing : -swing), foot), width: h * 0.08, coat)
        }
        ellipse(f.x + w * 0.15, f.y + h * 0.3, w * 0.7, h * 0.38, coat)
        circle(headX, f.y + h * (kind == .deer ? 0.12 : 0.3), h * 0.16, coat)
        if kind == .deer {
            line((headX, f.y + h * 0.0), (headX - w * 0.05, f.y - h * 0.15), width: h * 0.03, c.color(0.45, 0.35, 0.25))
            line((headX, f.y + h * 0.0), (headX + w * 0.05, f.y - h * 0.15), width: h * 0.03, c.color(0.45, 0.35, 0.25))
            line((headX, f.y + h * 0.15), (f.x + w * (f.leftward ? 0.25 : 0.75), f.y + h * 0.4), width: h * 0.1, coat)
        } else {
            let tail = f.leftward ? f.x + w * 0.88 : f.x + w * 0.12
            line((tail, f.y + h * 0.42), (tail + (f.leftward ? w * 0.12 : -w * 0.12), f.y + h * 0.18), width: h * 0.06, coat)
        }
    }

    /// Cars' lights at dusk and night: a glow on the ground ahead.
    func headlights(_ figures: [Figure]) {
        for f in figures where f.visitor == .car {
            let ahead = f.leftward ? f.x - f.width * 0.5 : f.x + f.width
            ellipse(ahead, f.y + f.height * 0.55, f.width * 0.5, f.height * 0.45, CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 0.18))
        }
    }
}
