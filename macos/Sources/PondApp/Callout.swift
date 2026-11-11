// A card with an arrow pointing up at a toolbar button, over the top of the window (Find Cameras' card): the
// card and arrow are one shape, so its glass is one piece. Where the button is comes from AppKit (a toolbar
// item's view tells nothing to SwiftUI's geometry), from a view behind it that reports its middle.
import AppKit
import SwiftUI

/// A rounded rectangle with an arrow on its top edge (or its bottom, `pointsDown`), its tip `arrowX` from the
/// left.
struct Callout: Shape {
    /// How far under the toolbar's bottom edge a card's arrow begins: just clear of it, as a popover's would.
    static let belowToolbar: CGFloat = 2
    /// The toolbar's overflow button (»), its middle from the window's trailing edge: where a card opened from an item
    /// in the overflow menu points (AppKit says which items are in the toolbar, not where that button is).
    static let overflowFromTrailing: CGFloat = 26

    /// Its usual arrow's height and corners (what's inside follows them).
    static let arrowHeight: CGFloat = 10
    static let cornerRadius: CGFloat = 22

    var arrowX: CGFloat
    var arrowWidth: CGFloat = 24
    var arrowHeight: CGFloat = Callout.arrowHeight
    var cornerRadius: CGFloat = Callout.cornerRadius
    var pointsDown = false
    /// The arrow in the middle, whatever the width (rather than at `arrowX`).
    var centred = false
    /// Without an arrow (a card opened from the toolbar's overflow menu: its button's by the window's edge, where an
    /// arrow can't reach it without running over the edge): the card where it would be with one, the arrow's room
    /// kept clear above it (flush under the toolbar, it looked stuck to it).
    var arrow = true

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
        guard arrow else { return card }
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
    /// Reports how far this view's middle is from its window's trailing edge, as it moves and changes size; `probe`
    /// measures it on asking, too.
    func reportingMiddleFromTrailing(probe: MiddleProbe? = nil, inToolbar: ((Bool) -> Void)? = nil,
                                     _ report: @escaping (CGFloat) -> Void) -> some View {
        background(MiddleReporter(report: report, probe: probe, inToolbar: inToolbar))
    }

    /// The same, from its window's leading edge (for a button at the toolbar's leading end); `probe` measures it on
    /// asking, too (a toolbar item that moves without changing size, as when an item before it goes, says nothing).
    /// `inToolbar`: told as the item moves into the toolbar's overflow menu (false) and back (true).
    func reportingMiddleFromLeading(probe: MiddleProbe? = nil, inToolbar: ((Bool) -> Void)? = nil,
                                    _ report: @escaping (CGFloat) -> Void) -> some View {
        background(MiddleReporter(report: report, fromLeading: true, probe: probe, inToolbar: inToolbar))
    }
}

/// Where a reporting view's middle is now, measured when asked.
final class MiddleProbe {
    fileprivate weak var view: ReportingView?

    /// From the window's leading edge, now (the toolbar's laid out by the time anyone clicks); nil while the item's
    /// in the toolbar's overflow menu (its view in no window), chosen from there.
    @MainActor var middleFromLeading: CGFloat? {
        guard let view, let content = view.window?.contentView else { return nil }
        return view.convert(view.bounds, to: content).midX
    }

    /// The same, from the window's trailing edge.
    @MainActor var middleFromTrailing: CGFloat? {
        guard let view, let content = view.window?.contentView else { return nil }
        return content.bounds.width - view.convert(view.bounds, to: content).midX
    }
}

private struct MiddleReporter: NSViewRepresentable {
    var report: (CGFloat) -> Void
    var fromLeading = false
    var probe: MiddleProbe?
    var inToolbar: ((Bool) -> Void)?

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.report = report
        view.fromLeading = fromLeading
        view.inToolbar = inToolbar
        probe?.view = view
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.report = report
        view.fromLeading = fromLeading
        view.inToolbar = inToolbar
    }
}

/// Tells its middle's distance from the window's trailing edge when it changes size, moves into a window, or
/// the window changes size (which moves the toolbar's trailing items with it).
final class ReportingView: NSView {
    var report: (CGFloat) -> Void = { _ in }
    var fromLeading = false
    /// Told whether it's in a window: a toolbar item's view leaves it as the item goes into the overflow menu.
    var inToolbar: ((Bool) -> Void)?
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
        let shown = window != nil
        DispatchQueue.main.async { [weak self] in self?.inToolbar?(shown) }
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

extension View {
    /// Reports this view's frame in its window's content (from the leading edge), as it moves and changes size: for a
    /// toolbar item, whose geometry SwiftUI doesn't tell.
    func reportingFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        background(FrameReporter(report: report))
    }
}

private struct FrameReporter: NSViewRepresentable {
    var report: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.report = report
        return view
    }

    func updateNSView(_ view: FrameReportingView, context: Context) {
        view.report = report
        view.tell()
    }
}

final class FrameReportingView: NSView {
    var report: (CGRect) -> Void = { _ in }
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

    func tell() {
        // After the toolbar has laid out.
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.window?.contentView else { return }
            self.report(self.convert(self.bounds, to: content))
        }
    }
}
