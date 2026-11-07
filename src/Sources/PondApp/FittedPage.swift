// A page that fits its window (the doctor's camera and recorder pages): the form's sections above, at their own
// height and not scrolling, then one card under them taking the rest of the window by layout alone (a list that
// grows and shrinks with the window, never under its shortest). Only a window too short for even that scrolls the
// whole page. Nothing is measured against itself: the sections' height doesn't depend on the card's, so there's no
// loop of measuring and resizing to settle (or not).
import SwiftUI

/// Where a page's cards stand in the Cameras window, its forms' sections and what's laid out beside a form (a page's
/// last card, a bar of buttons under it) alike, so nothing on a page, or from one page to the next, steps in or out,
/// whatever the page's width. A grouped form's sections are never wider than `readable`, centred (measured: the
/// form says neither), and at least `side` from the page's sides (pageForm); what's beside a form does the same
/// (besideForm).
enum PageMargin {
    /// The least margin at a page's sides.
    static let side = 30.0
    /// The widest a grouped form's sections go; past it, the margins grow.
    static let readable = 704.0
    /// A grouped form's own inset of its sections, inside its content margins.
    static let formInset = 20.0
}

extension View {
    /// A page's form in the Cameras window: grouped, its sections PageMargin.side from the page's sides whatever the
    /// page's width (left to itself, a grouped form widens its margins as it widens, and they'd part from the card's).
    func pageForm() -> some View {
        formStyle(.grouped)
            .contentMargins(.horizontal, PageMargin.side - PageMargin.formInset, for: .scrollContent)
    }

    /// Something laid out beside a page's form (under it), in line with its sections: as wide as they are, centred.
    func besideForm() -> some View {
        frame(maxWidth: PageMargin.readable)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PageMargin.side)
    }
}

struct FittedPage<Above: View, Card: View>: View {
    /// The card's least height.
    let shortest: Double
    @ViewBuilder let above: Above
    @ViewBuilder let card: Card
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
                .pageForm()
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
                .besideForm()
                .padding(.bottom, PageMargin.side)
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
