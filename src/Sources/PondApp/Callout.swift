// A card with an arrow pointing up at a toolbar button, over the top of the window (Find Cameras' card): the
// card and arrow are one shape, so its glass is one piece. Where the button is comes from AppKit (a toolbar
// item's view tells nothing to SwiftUI's geometry), from a view behind it that reports its middle.
import AppKit
import SwiftUI

/// A rounded rectangle with an arrow on its top edge (or its bottom, `pointsDown`), its tip `arrowX` from the
/// left.
struct Callout: Shape {
    var arrowX: CGFloat
    var arrowWidth: CGFloat = 24
    var arrowHeight: CGFloat = 10
    var cornerRadius: CGFloat = 22
    var pointsDown = false
    /// The arrow in the middle, whatever the width (rather than at `arrowX`).
    var centred = false

    var animatableData: CGFloat {
        get { arrowX }
        set { arrowX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let up = pointingUp(in: rect)
        // Pointing down: the same, upside down.
        return pointsDown ? up.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY)) : up
    }

    func pointingUp(in rect: CGRect) -> Path {
        var body = rect
        body.origin.y += arrowHeight
        body.size.height -= arrowHeight
        let card = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)
        // Kept clear of the corners.
        let x = min(max(centred ? rect.midX : arrowX, body.minX + cornerRadius + arrowWidth / 2), body.maxX - cornerRadius - arrowWidth / 2)
        let half = arrowWidth / 2
        var arrow = Path()
        // Into the card a little, so the two join; the sides curve into the edge and round off at the tip.
        arrow.move(to: CGPoint(x: x - half - 4, y: body.minY + 1))
        arrow.addQuadCurve(to: CGPoint(x: x - half / 2.6, y: rect.minY + arrowHeight * 0.3),
                           control: CGPoint(x: x - half, y: body.minY))
        arrow.addQuadCurve(to: CGPoint(x: x + half / 2.6, y: rect.minY + arrowHeight * 0.3),
                           control: CGPoint(x: x, y: rect.minY - arrowHeight * 0.15))
        arrow.addQuadCurve(to: CGPoint(x: x + half + 4, y: body.minY + 1),
                           control: CGPoint(x: x + half, y: body.minY))
        arrow.closeSubpath()
        return card.union(arrow)
    }
}

extension View {
    /// Reports how far this view's middle is from its window's trailing edge, as it moves and changes size.
    func reportingMiddleFromTrailing(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(MiddleReporter(report: report))
    }

    /// The same, from its window's leading edge (for a button at the toolbar's leading end).
    func reportingMiddleFromLeading(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(MiddleReporter(report: report, fromLeading: true))
    }
}

private struct MiddleReporter: NSViewRepresentable {
    var report: (CGFloat) -> Void
    var fromLeading = false

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.report = report
        view.fromLeading = fromLeading
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.report = report
        view.fromLeading = fromLeading
    }
}

/// Tells its middle's distance from the window's trailing edge when it changes size, moves into a window, or
/// the window changes size (which moves the toolbar's trailing items with it).
final class ReportingView: NSView {
    var report: (CGFloat) -> Void = { _ in }
    var fromLeading = false
    private var resizing: NSObjectProtocol?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tell()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizing { NotificationCenter.default.removeObserver(resizing) }
        resizing = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: $0, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tell() }
            }
        }
        tell()
    }

    private func tell() {
        guard let window, let content = window.contentView else { return }
        // After the toolbar has laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            let frame = self.convert(self.bounds, to: content)
            self.report(self.fromLeading ? frame.midX : content.bounds.width - frame.midX)
        }
    }
}
