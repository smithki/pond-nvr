// A settings page whose list (the recorder's log, a camera's history in the doctor) takes the room the page leaves,
// so the page fits its window without scrolling while it can. Two measures, neither moved by the page's scrolling, so
// the list and the page never chase each other (the list growing as the page scrolled, the page scrolling on):
// - the page's content taller than its window (from its scroll view): the list made shorter by as much, down to its
//   shortest; past that, the page scrolls, with a scroll bar, as any page does;
// - the page fitting (its scroll view then counts its content as the window's height, so that can't say how much room
//   is spare): the list grown until its bottom sits the form's margin above the window's bottom. A page that fits
//   doesn't scroll, so where the list ends holds still.
import SwiftUI

/// Where the list ends, and the page around it, as measured.
struct PageRoom: Equatable {
    var listBottom: Double?
    var pageHeight = 0.0
    var overflow = 0.0

    static let space = "page room"
    /// Between the list's card and the window's bottom edge: the form's margin at its sides.
    static let margin = 20.0
}

extension View {
    /// On the page's form: its list kept at `height`, never under `minimum`.
    func fillsRoom(_ height: Binding<Double>, minimum: Double, room: Binding<PageRoom>) -> some View {
        coordinateSpace(.named(PageRoom.space))
            .onGeometryChange(for: Double.self) { $0.size.height } action: { room.wrappedValue.pageHeight = $0 }
            .onScrollGeometryChange(for: Double.self) { g in
                g.contentSize.height - (g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom)
            } action: { _, over in room.wrappedValue.overflow = over }
            .onChange(of: room.wrappedValue, initial: true) { _, now in
                var next = height.wrappedValue
                if now.overflow > 0.5 {
                    next -= now.overflow
                } else if let bottom = now.listBottom, now.pageHeight > 0 {
                    next += now.pageHeight - PageRoom.margin - bottom
                }
                next = max(minimum, next.rounded(.down))
                if abs(next - height.wrappedValue) >= 1 { height.wrappedValue = next }
            }
    }

    /// On the list: where it ends, for the page's `fillsRoom`.
    func endsPageRoom(_ room: Binding<PageRoom>) -> some View {
        onGeometryChange(for: Double.self) { $0.frame(in: .named(PageRoom.space)).maxY } action: { room.wrappedValue.listBottom = $0 }
    }
}
