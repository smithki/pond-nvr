// The recorder's log in Settings: its last lines and then what it adds, earlier ones a piece at a time when
// asked for, and filters for what a line is about and what kind it is.
import AppKit
import Control
import PondCore
import SwiftUI

/// What the app has read of the service's log.
@MainActor
@Observable
final class ServiceLog {
    private(set) var lines: [LogLine] = []
    /// Every source seen, for the filter.
    private(set) var sources: Set<String> = []
    private(set) var hasEarlier = false
    @ObservationIgnored private var reader: LogReader?
    /// Lines let go from the start to make room: earlier ones are no longer offered.
    @ObservationIgnored private var trimmed = false

    /// At most this many lines are kept (some 2 MB).
    static let maxLines = 20_000

    /// The last lines the first time; then what was added since.
    func refresh() {
        if let reader {
            let added = reader.newer()
            guard !added.isEmpty else { return }
            lines += added
            sources.formUnion(added.map(\.source))
            if lines.count > Self.maxLines {
                lines.removeFirst(lines.count - Self.maxLines)
                trimmed = true
            }
            hasEarlier = !trimmed && reader.hasEarlier
        } else {
            let reader = LogReader(path: LaunchAgent.logPath)
            self.reader = reader
            lines = reader.latest()
            sources = Set(lines.map(\.source))
            hasEarlier = reader.hasEarlier
        }
    }

    func loadEarlier() {
        guard let reader, !trimmed, lines.count < Self.maxLines else { return }
        let earlier = reader.earlier()
        lines = earlier + lines
        sources.formUnion(earlier.map(\.source))
        hasEarlier = reader.hasEarlier && lines.count < Self.maxLines
    }
}

/// Which lines to show, by kind.
enum LogKindFilter: String, CaseIterable {
    case all, events, problems

    var title: String {
        switch self {
        case .all: "Everything"
        case .events: "Events"
        case .problems: "Problems"
        }
    }

    func includes(_ kind: LogLine.Kind) -> Bool {
        switch self {
        case .all: true
        case .events: kind != .detail
        case .problems: kind == .error || kind == .warning
        }
    }
}

struct LogSection: View {
    @Environment(AppModel.self) private var model
    let log: ServiceLog
    /// The source shown; empty: all of them.
    @State private var source = ""
    @State private var kind = LogKindFilter.events
    @State private var search = ""

    var cameras: [Config.Camera] { model.config?.cameras ?? [] }

    /// The sources to choose from: the recorder, HomeKit, the cameras in their order, then anything else seen.
    var sourceChoices: [String] {
        let known = [Brand.command, "homekit"] + cameras.map(\.id)
        return known + log.sources.subtracting(known).subtracting([""]).sorted()
    }

    func name(of source: String) -> String {
        switch source {
        case Brand.command: "Recorder"
        case "homekit": "HomeKit"
        default: cameras.first { $0.id == source }?.name ?? source
        }
    }

    /// The lines shown.
    var shown: [LogLine] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return log.lines.filter {
            kind.includes($0.kind) && (source.isEmpty || $0.source == source)
                && (needle.isEmpty || $0.message.localizedCaseInsensitiveContains(needle))
        }
    }

    /// A card of its own (PageCard), at the foot of its page: its filters, the lines taking the card's room, and
    /// where the log is.
    var body: some View {
        PageCard {
            Text("Log")
        } content: {
            VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Source", selection: $source) {
                    Text("All sources").tag("")
                    Divider()
                    ForEach(sourceChoices, id: \.self) { Text(name(of: $0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Kind", selection: $kind) {
                    ForEach(LogKindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Filter", text: $search, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            .padding(10)
            Divider().padding(.horizontal, 10)
            lines
            Divider().padding(.horizontal, 10)
            HStack {
                Text(LaunchAgent.logPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LaunchAgent.logPath)])
                } label: {
                    Image(systemName: "finder")
                }
                .help("Show in Finder")
                Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: LaunchAgent.logPath)) }
            }
            .disabled(log.lines.isEmpty)
            .padding(10)
            }
        }
    }

    @ViewBuilder
    var lines: some View {
        let rows = shown
        // The card's room whatever it shows, edge to edge between its separators.
        Group {
            if log.lines.isEmpty {
                Text("Nothing logged yet.").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No lines match.").foregroundStyle(.secondary)
            } else {
                // Scrolled to the top, earlier lines are read in above. The text is made from the lines only when they
                // or the filters change (not each time the page is laid out, as it is on every step of a resize).
                LogText(text: { LogFormat.text(rows, source: name(of:), dayTitle: dayTitle) },
                        first: rows.first?.id ?? 0, last: rows.last?.id ?? 0, filter: "\(source)|\(kind)|\(search)",
                        wantsEarlier: log.hasEarlier, loadEarlier: { log.loadEarlier() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reads a line's day (made once: a formatter is slow to make).
    static let dayFormat: DateFormatter = {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        return parse
    }()

    func dayTitle(_ day: Substring) -> String {
        guard let date = Self.dayFormat.date(from: String(day)) else { return String(day) }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }
}

/// The lines as text in columns (time, mark, source, message), long messages wrapping under their own
/// column, with a heading where a day starts.
@MainActor
enum LogFormat {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let column = ("0" as NSString).size(withAttributes: [.font: font]).width
    /// Where each column starts, in characters.
    static let markAt = 10.0, sourceAt = 12.0, messageAt = 26.0

    /// Every line (a wrapped one's every row, a day's heading, the marks from another font) exactly this
    /// tall: the view is cut between two lines, never through one.
    static let lineHeight = 14.0, lineSpacing = 2.0
    static var row: Double { lineHeight + lineSpacing }

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [markAt, sourceAt, messageAt].map { NSTextTab(textAlignment: .left, location: $0 * column) }
        style.headIndent = messageAt * column
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineSpacing = lineSpacing
        return style
    }()

    static func text(_ lines: [LogLine], source name: (String) -> String, dayTitle: (Substring) -> String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let primary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        var day: Substring?
        for line in lines {
            if line.day != day, !line.day.isEmpty {
                // A blank line before it (a line's height, as everything is), and the day.
                out.append(NSAttributedString(string: (out.length > 0 ? "\n" : "") + dayTitle(line.day) + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]))
            }
            day = line.day
            out.append(NSAttributedString(string: line.clock + "\t", attributes: secondary))
            let (mark, color): (String, NSColor) = switch line.kind {
            case .error: ("✗", .systemRed)
            case .warning: ("!", .systemOrange)
            case .done: ("✓", .systemGreen)
            case .detail, .event: ("", .clear)
            }
            var marked = secondary
            marked[.foregroundColor] = color
            out.append(NSAttributedString(string: mark + "\t", attributes: marked))
            let source = name(line.source)
            out.append(NSAttributedString(string: (source.count > 12 ? source.prefix(11) + "…" : source) + "\t", attributes: secondary))
            out.append(NSAttributedString(string: message(line) + "\n", attributes: line.kind == .detail ? secondary : primary))
        }
        // No line break after the last line: it would make an empty line below it.
        if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// The message, without the "HomeKit: " that HomeKit's lines start with (the source says so).
    static func message(_ line: LogLine) -> Substring {
        let said = line.message[...]
        return line.source == "homekit" && said.hasPrefix("HomeKit: ") ? said.dropFirst(9) : said
    }
}

/// The log text, selectable, in its own scroll view: at the newest lines, kept there as more come; where it
/// was, if scrolled up; and the same lines in view when earlier ones are added above.
struct LogText: NSViewRepresentable {
    /// The text, made when it's needed (the lines or filters changed).
    let text: () -> NSAttributedString
    /// The first and last lines' ids, and the filters: what changed.
    let first: Int
    let last: Int
    let filter: String
    /// Whether there are earlier lines to read, and reading them.
    let wantsEarlier: Bool
    let loadEarlier: () -> Void

    /// Space above the first line and (at least) below the last: none, as the form's row has its own.
    static let top = 0.0, minBottom = 0.0

    @MainActor
    final class Coordinator {
        var first: Int?
        var last: Int?
        var filter: String?
        var wantsEarlier = false
        var loadEarlier: () -> Void = {}
        var asked = false
        /// Shown at its size and scrolled to the end: before that, its top is no sign of wanting more.
        var ready = false
        /// Following the newest lines: at the end until scrolled away from it, and kept there through
        /// resizes and new lines.
        var pinned = true
        private var size = NSSize.zero
        weak var scroll: NSScrollView?

        /// Scrolled, or resized (the tab measured, the window changed).
        func boundsChanged() {
            // Not laid out yet: nothing has been scrolled.
            guard let scroll, let view = scroll.documentView, scroll.contentView.bounds.height > 0 else { return }
            let clip = scroll.contentView
            if clip.bounds.size != size {
                size = clip.bounds.size
                if pinned { scrollToEnd() }
                return
            }
            pinned = clip.bounds.maxY >= view.frame.height - 4
            checkTop()
        }

        /// The text grew or shrank (new lines, or wrapped again at a new width).
        func textResized() {
            if pinned { scrollToEnd() }
        }

        /// To the last line, with the top of the view between two lines: the space below the last line is
        /// what whole lines leave over (at least `minBottom`), rather than a line cut through at the top.
        func scrollToEnd() {
            guard let scroll, let view = scroll.documentView as? LogTextView else { return }
            let clip = scroll.contentView
            let height = clip.bounds.height
            guard height > 0 else { return }
            let lines = view.frame.height - LogText.top - view.bottomSpace
            if lines + LogText.top + LogText.minBottom > height {
                // Scrolled to the end, the top is at top + lines + space - height: a whole number of rows down.
                let row = LogFormat.row
                var space = (height - lines).truncatingRemainder(dividingBy: row)
                if space < 0 { space += row }
                while space < LogText.minBottom { space += row }
                if space != view.bottomSpace { view.bottomSpace = space }
            }
            clip.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - height)))
            scroll.reflectScrolledClipView(clip)
        }

        /// At the top (or with nothing to scroll), earlier lines are asked for; once until they come.
        func checkTop() {
            guard ready, wantsEarlier, !asked, let scroll, let view = scroll.documentView else { return }
            let clip = scroll.contentView
            guard clip.bounds.minY < 40 || view.frame.height <= clip.bounds.height else { return }
            asked = true
            DispatchQueue.main.async { self.loadEarlier() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // TextKit 1: the whole text laid out, so its height (and where its end is) is known at once.
        let view = LogTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.bottomSpace = Self.minBottom
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.scroll = scroll
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { coordinator.boundsChanged() }
        }
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
            MainActor.assumeIsolated { coordinator.textResized() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let was = context.coordinator
        was.loadEarlier = loadEarlier
        // Whatever was asked for has come (if it was all filtered out, and the top is still in view, more).
        was.asked = false
        was.wantsEarlier = wantsEarlier
        defer { was.checkTop() }

        guard was.first != first || was.last != last || was.filter != filter,
              let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let clip = scroll.contentView
        let fromBottom = view.frame.height - clip.bounds.minY, fromTop = clip.bounds.minY
        let fresh = was.filter != filter || was.first == nil
        let addedAbove = !fresh && first < (was.first ?? first)
        if fresh { was.pinned = true }
        storage.setAttributedString(text())
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        if was.pinned {
            was.scrollToEnd()
            // Again once it is laid out at its size: the first time, it has none yet.
            if fresh {
                was.ready = false
                DispatchQueue.main.async {
                    was.scrollToEnd()
                    was.ready = true
                    was.checkTop()
                }
            }
        } else {
            let y = addedAbove ? view.frame.height - fromBottom : fromTop
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(clip)
        }
        was.first = first
        was.last = last
        was.filter = filter
    }
}



/// The log's text view: `LogText.top` above the first line, and `bottomSpace` below the last.
final class LogTextView: NSTextView {
    var bottomSpace = LogText.minBottom {
        didSet {
            // The inset counts above and below; the text is drawn from `top` (textContainerOrigin), so the
            // rest of twice the inset is below it.
            textContainerInset = NSSize(width: 4, height: (LogText.top + bottomSpace) / 2)
            sizeToFit()
        }
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: 4, y: LogText.top) }
}



