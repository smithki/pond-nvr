// A page that fits its window (the doctor's camera and recorder pages): the form's sections above, at their own
// height and not scrolling, then one card under them taking the rest of the window by layout alone (a list that
// grows and shrinks with the window, never under its shortest). Only a window too short for even that scrolls the
// whole page. Nothing is measured against itself: the sections' height doesn't depend on the card's, so there's no
// loop of measuring and resizing to settle (or not).
import SwiftUI

struct FittedPage<Above: View, Card: View>: View {
    /// The card's least height.
    let shortest: Double
    @ViewBuilder let above: Above
    @ViewBuilder let card: Card
    /// The form's margin at its sides, kept under the card too.
    static var margin: Double { 20 }
    /// Between the form's last section and the card's heading, as between the form's own.
    static var headingGap: Double { 10 }
    /// The sections' height, as their form lays them out.
    @State private var aboveHeight = 0.0

    var body: some View {
        ViewThatFits(in: .vertical) {
            page(fills: true)
            ScrollView { page(fills: false) }.scrollIndicators(.never)
        }
    }

    func page(fills: Bool) -> some View {
        VStack(spacing: 0) {
            Form { above }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollIndicators(.never)
                // Its content's height. (Not with the inset a window's toolbar gives it at the top: the form is under the
                // toolbar already, in the page's safe area, so that inset only reaches up behind it.)
                .onScrollGeometryChange(for: Double.self) { g in
                    g.contentSize.height + g.contentInsets.bottom
                } action: { _, height in
                    if abs(height - aboveHeight) >= 1 { aboveHeight = height }
                }
                .frame(height: aboveHeight)
            card
                .frame(minHeight: shortest, idealHeight: shortest, maxHeight: fills ? .infinity : shortest)
                // As far under the sections as the form keeps its sections apart.
                .padding(.top, Self.headingGap)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.margin)
        }
    }
}

/// A card like a grouped form's section, under its heading, for a page's last part (FittedPage): its content fills it.
struct PageCard<Heading: View, Content: View>: View {
    @ViewBuilder let heading: Heading
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
                .font(.headline)
                .padding(.horizontal, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
