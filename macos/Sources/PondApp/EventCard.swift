// A card in the Events grid: an event's picture, its subject boxed and its kind on it, what happened, where and
// when; and the glow round one just come in.
import AppKit
import SwiftUI

/// One event: its picture with its subject boxed and its kind on it, what happened, where and when. A click opens its
/// details; two, the timeline there.
struct EventCard: View, Equatable {
    let event: TimelineEvent
    let camera: String
    let selected: Bool
    /// Just come in: glows a moment.
    var fresh = false
    /// Not seen yet: the card washed with the accent, and a dot at the end of its last line.
    var isNew = false
    /// Its width, where it's going (the grid's frame for it): its words laid out for that once, not as it gets there.
    let width: Double
    let choose: () -> Void
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @Environment(AppModel.self) private var model

    var aspect: Double { CameraAspect.known(event.camera) ?? 16.0 / 9.0 }

    /// The same if it shows the same (its actions, made anew with each of the grid's, aren't compared).
    nonisolated static func == (a: EventCard, b: EventCard) -> Bool {
        a.event == b.event && a.camera == b.camera && a.selected == b.selected && a.fresh == b.fresh && a.isNew == b.isNew && a.width == b.width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EventPicture(event: event, aspect: aspect, frame: 16.0 / 9.0)
            // Its words, as wide as the card's to be: as the card's width changes (the panel coming or going), those
            // for the old width fade into those for the new, each still (reflowing, a frame at a time, they
            // squirmed, and drawing them each frame was a quarter of the main thread's time).
            ZStack(alignment: .topLeading) {
                if let leaving {
                    words(for: leaving).opacity(leavingOpacity)
                }
                words(for: width).opacity(1 - leavingOpacity)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: EventGridLayout.textHeight, maxHeight: EventGridLayout.textHeight, alignment: .topLeading)
            .clipped()
            .onChange(of: width) { old, new in
                // (Not for a window being resized a little at a time: there the words simply follow.)
                guard abs(new - old) > 8 else { return }
                leaving = old
                leavingOpacity = 1
                withAnimation(.easeInOut(duration: Self.crossfade)) { leavingOpacity = 0 } completion: {
                    if leavingOpacity == 0 { leaving = nil }
                }
            }
        }
        .padding(EventGridLayout.pad)
        .background(.quaternary.opacity(hovering || selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Not seen yet: the card washed with the accent, fading as it's seen (no change to its size or words).
        .background(Color.accentColor.opacity(isNew ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: isNew)
        // (Its outline, chosen, is the grid's: drawn over it, moving and resizing with it exactly.)
        // Always there, switched on and off (one inserted and removed would fade where the card was).
        .overlay { NewEventGlow(color: event.kind.color, cornerRadius: 14, active: fresh) }
        // Resized as one (the panel opening): its picture, words and glow all at the size it is part way, not each
        // going to its new size on its own.
        .geometryGroup()
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) { if event.pond == nil { open() } else { choose() } }
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(event.pond == nil ? "Click for details, double-click to watch on the timeline" : "Click for details and its clip")
        .contextMenu {
            // (Another Pond's: not on this Mac's timeline, nor deleted from here.)
            if event.pond == nil { Button("Watch on the Timeline", action: open) }
            if let snapshot = event.snapshot {
                Button("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot]) }
            }
            if event.pond == nil {
                // What it was (for what's like it, from now on).
                Divider()
                if event.quieted != nil {
                    Button("It Was Something", systemImage: "exclamationmark.bubble") { model.say(.something, of: event) }
                } else {
                    Button("This Wasn\u{2019}t Anything", systemImage: "moon.zzz") { model.say(.nothing, of: event) }
                }
                // Its camera, from here: its settings, its zones, and this event's area left alone from now on.
                Divider()
                Button("Ignore This Area\u{2026}", systemImage: "eye.slash") { model.editZones(event.camera, ignoring: event) }
                    .disabled(!model.canEditZones(event.camera) || event.box == nil)
                Button("Edit Zones\u{2026}", systemImage: "square.dashed") { model.editZones(event.camera) }
                    .disabled(!model.canEditZones(event.camera))
                Button("Camera Settings\u{2026}", systemImage: "gearshape") {
                    model.editCameraSettings(event.camera)
                }
                Divider()
                Button("Delete Event…", role: .destructive, action: delete)
            }
        }
    }

    /// Its sentence, and the line under it: camera, time, how long.
    /// Laid out for a card `width` wide, at once (never a width on the way from one to another).
    func words(for width: Double) -> some View {
        words
            .frame(width: max(0, width - 2 * EventGridLayout.pad - 8), alignment: .leading)
            .animation(nil, value: width)
    }

    /// The width its words were laid out for before, fading out (as those for its width now fade in), and how far.
    @State private var leaving: Double?
    @State private var leavingOpacity = 0.0
    static let crossfade = 0.3

    var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.summary)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            // Not seen yet: a dot at the end of this line, in room kept for it whether it's there or not, so
            // nothing moves as it's seen (a dot leading the sentence, and the sentence in semibold, both reflowed
            // its words as it was read).
            Text("\(camera) \u{00B7} \(event.start.formatted(date: .omitted, time: .shortened)) \u{00B7} \(event.quieted?.words ?? EventCallout.length(event.seconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .opacity(isNew ? 1 : 0)
                        .scaleEffect(isNew ? 1 : 0.4)
                        .accessibilityLabel("Unread")
                        .accessibilityHidden(!isNew)
                }
                .animation(.easeOut(duration: 0.3), value: isNew)
        }
    }
}

/// An event's picture, its subject boxed, its kind in a badge.
struct EventPicture: View {
    let event: TimelineEvent
    @Environment(AppModel.self) private var model
    /// Another Pond's picture, fetched since it was first drawn; or this Mac's, read since.
    @State private var fetched = false
    @State private var read = false
    /// The picture's own shape.
    let aspect: Double
    /// The shape it's shown in (the grid's, alike for every card: a picture of another shape fills it, cropped);
    /// nil, its own.
    var frame: Double?

    var body: some View {
        // (Read again once another Pond's has been fetched, or this one's read.)
        let _ = (fetched, read)
        // Never read here, on the main thread: a card made before its picture's been read (the grid's read ahead of
        // the scroll, but not of the scroll thumb dragged across days) shows its kind until it is. Read as each was
        // made, screens of them at a time, they stuttered.
        let image = event.snapshot.flatMap(EventPictures.kept)
        // The picture's own shape (from the picture, when there is one), and the frame's: the frame alone sizes the
        // card (a box of its shape), the picture filling it, cropped, so every card in the grid is alike.
        let own = image.map { $0.size.height > 0 ? Double($0.size.width / $0.size.height) : aspect } ?? aspect
        let shown = frame ?? own
        Color.clear
            .aspectRatio(shown, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: event.kind.symbol).font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
            .overlay {
                if let box = event.box {
                    GeometryReader { geo in
                        // The picture as it fills the frame (centred, the overflow cropped), the box on it.
                        let w = geo.size.width, h = geo.size.height
                        let picture = own > w / h ? CGSize(width: h * own, height: h) : CGSize(width: w, height: w / own)
                        let dx = (w - picture.width) / 2, dy = (h - picture.height) / 2
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(event.kind.color, lineWidth: 2)
                            .frame(width: box.width * picture.width, height: box.height * picture.height)
                            .position(x: dx + (box.x + box.width / 2) * picture.width, y: dy + (box.y + box.height / 2) * picture.height)
                    }
                }
            }
            // Small, in the top-right corner: the top-left is where many cameras print their clock.
            .overlay(alignment: .topTrailing) { KindBadge(event: event, compact: true).padding(6) }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .task(id: event.snapshot) {
                guard image == nil, let url = event.snapshot, event.pond == nil else { return }
                if await EventPictures.load(url) != nil { read = true }
            }
            // Another Pond's, fetched as it's first shown.
            .task(id: event.id) {
                guard event.pond != nil, image == nil else { return }
                if await AppModel.fetchPicture(event, client: model.controlClient) { fetched = true }
            }
    }
}

struct KindBadge: View {
    let event: TimelineEvent
    /// Its symbol only (its colour and the card's words say the rest), covering as little of the picture as it can.
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: event.kind.symbol)
                // Compact, a square for the symbol, so every kind's badge is the same circle (a person's symbol is
                // narrower than a car's).
                .frame(width: compact ? 13 : nil, height: compact ? 13 : nil)
            if !compact { Text(event.kind.title) }
            // Still going on: the timeline's live dot, in white (red text on the kind's colour read poorly), with its
            // word beside it where there's room.
            if event.ongoing {
                LiveDot(active: true, color: .white)
                if !compact { Text("Now") }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, compact && !event.ongoing ? 5 : 8)
        .padding(.vertical, compact && !event.ongoing ? 5 : 4)
        // A plain capsule, not glass: there's one on every card, and glass on each is costly to redraw as they move.
        .background(event.kind.color.opacity(0.85), in: Capsule())
        // Its word for VoiceOver, not a tooltip: a tooltip on every card is a region the window tracks, moved with each
        // card, and made the grid's moves (the detail panel opening and closing) choppy.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.ongoing ? "\(event.kind.title), happening now" : event.kind.title)
    }
}

/// Round a card just come in: a ring in its kind's colour that glows up as it lands and settles away, as a camera
/// just added to the live view does.
struct NewEventGlow: View {
    let color: Color
    let cornerRadius: Double
    let active: Bool

    /// How long it glows.
    static let lasts = 3.5

    var change: Animation { active ? .spring(duration: 0.5, bounce: 0.35).delay(0.35) : .easeOut(duration: 0.8) }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 3)
            // Only its own glow animates: its place and size are the card's.
            .animation(change) { ring in
                ring.shadow(color: color.opacity(0.9), radius: active ? 12 : 0)
                    .shadow(color: color.opacity(0.5), radius: active ? 24 : 0)
                    .opacity(active ? 1 : 0)
            }
            .allowsHitTesting(false)
    }
}
