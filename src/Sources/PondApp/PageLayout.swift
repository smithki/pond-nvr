// How a Settings page is laid out: its cards one width on every page (PageMargin), and a page whose last card is a
// log's newest lines (the recorder's, a camera's What happened: LogPage), that card one height on every page, not
// scrolling (the whole log is a sheet: FullLogSheet), and the page scrolling as a whole, as the others do. Nothing is measured against itself: the sections' height doesn't depend on
// the card's, so there's no loop of measuring and resizing to settle (or not).
import SwiftUI

/// Where a page’s cards stand in the Settings window, its forms' sections and what's laid out beside a form (a page's
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
    /// A page’s form in the Settings window: grouped, its sections PageMargin.side from the page's sides whatever the
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

struct LogPage<Above: View, Card: View>: View {
    @ViewBuilder let above: Above
    /// Its last section: a PageCard.
    @ViewBuilder let card: Card
    /// A log card's height under its heading, on every page that has one (the recorder's log, a camera's What
    /// happened), whatever the window's: its newest dozen lines or so.
    static var cardHeight: Double { 220 }

    var body: some View {
        // One form, scrolling when the window's too short for it, as every other page's does: its cards in line with
        // theirs (a scroll view of its own kept its scroll bar's room at one side, with a mouse attached, and stood
        // the cards off centre). The card doesn't scroll: it shows the newest lines, and Show All… the whole log in a
        // sheet (FullLogSheet), so there's only ever one scroll bar on a page.
        Form {
            above
            card
        }
        .pageForm()
    }
}

/// A grouped form's section whose content is one thing of a fixed height, edge to edge in its card (a log's newest
/// lines: LogPage), under its heading.
struct PageCard<Heading: View, Content: View>: View {
    @ViewBuilder let heading: Heading
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
                .frame(maxWidth: .infinity)
                .frame(height: LogPage<EmptyView, EmptyView>.cardHeight)
                .listRowInsets(EdgeInsets())
        } header: {
            heading
        }
    }
}

/// A card's heading with what's done with the whole of it (Show All…) at its end, as a page's first heading has
/// its buttons (DoctorView.header).
struct CardHeading<Buttons: View>: View {
    let title: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            buttons.font(.body)
        }
        .controlSize(.small)
        .textCase(nil)
    }
}

/// The top of a card of a log's newest lines faded out, when there are more above than it shows: the line cut at
/// the top reads as the log going on (Show All… has it), not as a line cut short.
struct PeekFade: ViewModifier {
    let on: Bool
    static let height = 28.0

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: on ? Self.height : 0)
                Color.black
            }
        }
    }
}
