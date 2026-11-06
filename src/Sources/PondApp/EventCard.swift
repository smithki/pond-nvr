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
    /// Not seen yet: a dot by when it was.
    var isNew = false
    let choose: () -> Void
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var aspect: Double { CameraAspect.known(event.camera) ?? 16.0 / 9.0 }

    /// The same if it shows the same (its actions, made anew with each of the grid's, aren't compared).
    nonisolated static func == (a: EventCard, b: EventCard) -> Bool {
        a.event == b.event && a.camera == b.camera && a.selected == b.selected && a.fresh == b.fresh && a.isNew == b.isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EventPicture(event: event, aspect: aspect, frame: 16.0 / 9.0)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    // Not seen yet.
                    if isNew {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .help("New: not seen yet")
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text("\(camera) \u{00B7} \(event.start.formatted(date: .omitted, time: .shortened)) \u{00B7} \(event.quieted?.words ?? EventCallout.length(event.seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .animation(.easeOut(duration: 0.3), value: isNew)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: EventGridLayout.textHeight, maxHeight: EventGridLayout.textHeight, alignment: .topLeading)
        }
        .padding(EventGridLayout.pad)
        .background(.quaternary.opacity(hovering || selected ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    model.showCameraSettings(event.camera) { openSettings() }
                }
                Divider()
                Button("Delete Event…", role: .destructive, action: delete)
            }
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
            .overlay(alignment: .topLeading) { KindBadge(event: event).padding(8) }
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: event.kind.symbol)
            Text(event.kind.title)
            if event.ongoing { Text("Now").foregroundStyle(.red) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // A plain capsule, not glass: there's one on every card, and glass on each is costly to redraw as they move.
        .background(event.kind.color.opacity(0.85), in: Capsule())
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
