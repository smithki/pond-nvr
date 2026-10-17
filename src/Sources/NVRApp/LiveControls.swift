// The live controls dock: under a camera watched on its own, the controls it has (moving it, its kept
// positions, day and night), on glass, shown and hidden from the bottom of the stage. Built from small general
// pieces (a section, a press-and-hold button, a direction pad, a strip of chips, a choice of icons) that any
// control can use, a make's own included.
import Devices
import NVRCore
import SwiftUI

// MARK: - General pieces

/// A group in the dock: a small heading over its controls.
struct ControlSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

/// A group of adjustments' heading: its icon and name, a step above a control's name (which is small capitals).
struct GroupHeading: View {
    let group: Config.Controls.Item.Group

    var body: some View {
        Label {
            Text(group.title).font(.subheadline.weight(.semibold))
        } icon: {
            Image(systemName: group.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// A round glass button that acts while held: `began` on press, `ended` on release.
struct HoldButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 36
    let began: () -> Void
    let ended: () -> Void
    @State private var held = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .frame(width: size, height: size)
            .glassEffect(held ? .regular.tint(.accentColor.opacity(0.5)).interactive() : .regular.interactive(), in: .circle)
            .scaleEffect(held ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: held)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !held {
                        held = true
                        began()
                    }
                }
                .onEnded { _ in
                    held = false
                    ended()
                })
            .help(help)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(help)
    }
}

/// A pad to drag in a direction: the further from the middle, the faster, until let go. Around the knob, four
/// buttons like a remote's (a quarter of the ring each, lit under the pointer) move at a steady speed while
/// held. `changed` gets x (right +) and y (up +), each −1…1, or zero to stop.
struct DirectionPad: View {
    var size: CGFloat = 108
    let changed: (CGVector) -> Void
    @State private var knob: CGSize = .zero
    @State private var dragging = false
    @State private var hovered: Int?
    @State private var held: Int?

    var body: some View {
        let radius = size / 2, knobSize = size * 0.36, reach = radius - knobSize / 2 - 6
        let inner = knobSize / 2 + 5, outer = radius - 3
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular, in: .circle)
            // The four buttons round the knob.
            ForEach(Self.arrows.indices, id: \.self) { index in
                let arrow = Self.arrows[index]
                let segment = RingSegment(direction: arrow.angle, span: 90, gap: 6, inner: inner, outer: outer)
                let lit = held == index ? 0.32 : hovered == index ? 0.14 : 0
                segment
                    .fill(held == index ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.white.opacity(lit)))
                    .overlay {
                        Image(systemName: arrow.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(held == index || hovered == index ? .primary : .secondary)
                            .offset(x: arrow.vector.dx * (inner + outer) / 2, y: -arrow.vector.dy * (inner + outer) / 2)
                    }
                    .animation(.easeOut(duration: 0.12), value: hovered)
                    .animation(.easeOut(duration: 0.08), value: held)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(arrow.help)
            }
            // The ring's pointer, for all four at once: which one is under it is worked out from where it is
            // (a view's hover covers its whole frame, not its shape).
            Circle()
                .fill(.clear)
                .contentShape(Circle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point): hovered = Self.segment(at: point, size: size, inner: inner, outer: outer)
                    case .ended: hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard held == nil, let index = Self.segment(at: value.startLocation, size: size, inner: inner, outer: outer)
                        else { return }
                        held = index
                        changed(Self.arrows[index].vector.scaled(0.6))
                    }
                    .onEnded { _ in
                        if held != nil { changed(.zero) }
                        held = nil
                    })
                .help(hovered.map { Self.arrows[$0].help } ?? "")
            Circle()
                .fill(.clear)
                .frame(width: knobSize, height: knobSize)
                .glassEffect(dragging ? .regular.tint(.accentColor.opacity(0.45)).interactive() : .regular.interactive(), in: .circle)
                .offset(knob)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragging = true
                        var offset = value.translation
                        let length = hypot(offset.width, offset.height)
                        if length > reach { offset = CGSize(width: offset.width / length * reach, height: offset.height / length * reach) }
                        knob = offset
                        changed(CGVector(dx: offset.width / reach, dy: -offset.height / reach))
                    }
                    .onEnded { _ in
                        dragging = false
                        withAnimation(.spring(duration: 0.35, bounce: 0.35)) { knob = .zero }
                        changed(.zero)
                    })
                .help("Drag to move; further is faster")
        }
        .frame(width: size, height: size)
    }

    /// The button under `point` (in the pad's frame), if any: by its angle from the middle, between the radii.
    static func segment(at point: CGPoint, size: CGFloat, inner: CGFloat, outer: CGFloat) -> Int? {
        let dx = point.x - size / 2, dy = size / 2 - point.y
        let distance = hypot(dx, dy)
        guard distance >= inner, distance <= outer + 3 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        return arrows.firstIndex { arrow in
            let off = abs((angle - arrow.angle + 540).truncatingRemainder(dividingBy: 360) - 180)
            return off <= 45
        }
    }

    struct Arrow {
        let symbol: String
        let vector: CGVector
        /// Its direction, in degrees: 0 right, 90 up.
        let angle: Double
        let help: String
    }

    static let arrows = [
        Arrow(symbol: "chevron.up", vector: CGVector(dx: 0, dy: 1), angle: 90, help: "Tilt up"),
        Arrow(symbol: "chevron.down", vector: CGVector(dx: 0, dy: -1), angle: 270, help: "Tilt down"),
        Arrow(symbol: "chevron.left", vector: CGVector(dx: -1, dy: 0), angle: 180, help: "Pan left"),
        Arrow(symbol: "chevron.right", vector: CGVector(dx: 1, dy: 0), angle: 0, help: "Pan right"),
    ]
}

/// A piece of a ring: `span` degrees centred on `direction` (0 right, 90 up), between two radii, with half of
/// `gap` taken off each end so neighbours stand apart; its corners rounded.
struct RingSegment: Shape {
    let direction: Double
    let span: Double
    let gap: Double
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Screen angles run clockwise (y down): up is −90°.
        let from = Angle(degrees: -(direction + span / 2 - gap / 2))
        let to = Angle(degrees: -(direction - span / 2 + gap / 2))
        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        // Softened corners.
        return path.strokedPath(StrokeStyle(lineWidth: 4, lineJoin: .round)).union(path)
    }
}

extension CGVector {
    func scaled(_ factor: Double) -> CGVector { CGVector(dx: dx * factor, dy: dy * factor) }
}

/// A row of glass chips that scrolls sideways, with a button to add one at the end.
struct ChipStrip<Item: Identifiable, Menu: View>: View {
    let items: [Item]
    let title: (Item) -> String
    let tap: (Item) -> Void
    @ViewBuilder let menu: (Item) -> Menu
    var add: (() -> Void)?
    var addHelp = "Add"
    var empty = "None yet"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if items.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                ForEach(items) { item in
                    Button { tap(item) } label: {
                        Text(title(item)).font(.callout.weight(.medium)).lineLimit(1).padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .contextMenu { menu(item) }
                }
                if let add {
                    Button(action: add) { Image(systemName: "plus").font(.callout.weight(.semibold)) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help(addHelp)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }
}

/// A choice among a few, by icon, on glass: the chosen one lit. Glass buttons of the system's (glass painted
/// onto a plain button takes the pointer apart from the button, which then never hears the click).
struct IconChoice<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let systemImage: String
    }

    let options: [Option]
    let selection: Value?
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                let label = VStack(spacing: 3) {
                    Image(systemName: option.systemImage).font(.system(size: 15, weight: .semibold))
                    Text(option.title).font(.caption2.weight(.medium))
                }
                .frame(width: 38, height: 34)
                Group {
                    if chosen {
                        Button { choose(option.value) } label: { label }.buttonStyle(.glassProminent)
                    } else {
                        Button { choose(option.value) } label: { label }.buttonStyle(.glass)
                    }
                }
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .help(option.title)
            }
        }
        .animation(.snappy(duration: 0.25), value: selection)
    }
}

/// A camera's positions as cards: each its picture from the last time it was seen (a placeholder until then)
/// and its name; a click sends the camera there. As many as fit the width (no scrolling sideways); the last
/// place keeps where it points now, or, with more positions than fit, opens the others (and Keep) as cards, in
/// a grid.
struct PresetCards<Menu: View>: View {
    let camera: String
    let presets: [PTZPreset]
    let pictures: [String: NSImage]
    /// Moves a position (dragged) to where another is.
    var move: (String, String) -> Void = { _, _ in }
    let go: (PTZPreset) -> Void
    @ViewBuilder let menu: (PTZPreset) -> Menu
    let add: () -> Void
    /// Naming a new position: asked from the card that keeps one (Keep, or More when Keep is in its panel).
    var naming: Binding<Bool> = .constant(false)
    var namer: AnyView = AnyView(EmptyView())
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0
    var showingAll: Bool { model.morePositionsOpen == camera }
    /// A position just kept that went to More: its picture, dropping into the card.
    @State private var dropping: NSImage?
    @State private var dropped = false
    @State private var morePressed = false
    /// A position just kept that fits in the dock: lit for a moment.
    @State private var lit: String?
    /// What was in More before the latest change: one of these arriving in the dock comes out of More.
    @State private var lastRest: [String] = []
    /// The position being dragged (the rail's reordering: in the dock the others move out of its way; from the
    /// panel, the one it's over dims, and it takes that place when dropped).
    @State private var drag = ReorderDrag()

    static var size: CGSize { CGSize(width: 88, height: 50) }
    static var spacing: CGFloat { 10 }

    var body: some View {
        // How many fit, the last place for Keep or More.
        let places = max(1, Int((width + Self.spacing) / (Self.size.width + Self.spacing)))
        let shown = presets.count < places ? presets : Array(presets.prefix(places - 1))
        let rest = Array(presets.dropFirst(shown.count))
        HStack(spacing: Self.spacing) {
            ForEach(shown) { preset in
                card(preset, from: .positions) { go(preset) }
                    // A new one springs in; one from More (filling a place) pops out of the More card beside it.
                    // Removed: it shrinks away and fades, quickly.
                    .transition(.asymmetric(
                        insertion: lastRest.contains(preset.id)
                            ? .modifier(active: Displaced(x: Self.size.width + Self.spacing, scale: 0.2, opacity: 0),
                                        identity: Displaced(x: 0, scale: 1, opacity: 1))
                            : .scale(scale: 0.6).combined(with: .opacity),
                        removal: .scale(scale: 0.3).combined(with: .opacity).animation(.easeIn(duration: 0.16))))
                    .overlay {
                        if lit == AppModel.presetKey(camera, preset.id) {
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .frame(width: Self.size.width + 4, height: Self.size.height + 4)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .offset(y: -2)
                                .shadow(color: .accentColor.opacity(0.7), radius: 6)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
            }
            if rest.isEmpty {
                Button(action: add) {
                    tile(symbol: "plus", title: "Keep")
                }
                .buttonStyle(.plain)
                .help("Keep where it points now as a position")
                .popover(isPresented: naming, arrowEdge: .top) { namer }
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { model.morePositionsOpen = showingAll ? nil : camera }
                } label: {
                    tile(symbol: "ellipsis", title: "\(rest.count) More")
                        .scaleEffect(morePressed ? 0.9 : 1)
                        .overlay(alignment: .top) {
                            // A position just kept that went here: its picture shrinks into the card's middle.
                            if let dropping {
                                Image(nsImage: dropping).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: Self.size.width, height: Self.size.height)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 1) }
                                    .shadow(radius: 6)
                                    .scaleEffect(dropped ? 0.2 : 1.15)
                                    .opacity(dropped ? 0 : 1)
                                    .offset(y: dropped ? 0 : -Self.size.height * 0.35)
                                    .allowsHitTesting(false)
                                    // Fading in quickly, rather than just appearing.
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            }
                        }
                }
                    .buttonStyle(.plain)
                    .help("Its other positions")
                    // The others open above it, drawn by the dock (outside its edges): see MorePositions.
                    .popover(isPresented: naming, arrowEdge: .top) { namer }
                    .anchorPreference(key: MorePositions.self, value: .bounds) { anchor in
                        MorePositions.Panel(anchor: anchor, content: AnyView(others(rest)), ids: rest.map(\.id), open: showingAll)
                    }
            }
            Spacer(minLength: 0)
        }
        // Room for a card's hover to grow into.
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 8 } action: { width = $0 }
        // Something left More for the dock: More clicks as it comes out. Then the new list is what's in More.
        .onChange(of: rest.map(\.id)) { before, after in
            if before.contains(where: { id in shown.contains { $0.id == id } }) { clickMore() }
            lastRest = after
        }
        .onAppear { lastRest = rest.map(\.id) }
        .onChange(of: model.justKept) { _, kept in
            guard let kept, kept.hasPrefix(camera + "/") else { return }
            model.justKept = nil
            if rest.contains(where: { AppModel.presetKey(camera, $0.id) == kept }) {
                if let picture = pictures[kept] { dropIntoMore(picture) }
            } else {
                // In the dock: lit as it springs in, then the light fades.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.easeOut(duration: 0.2)) { lit = kept }
                    try? await Task.sleep(for: .milliseconds(1100))
                    withAnimation(.easeOut(duration: 0.6)) { if lit == kept { lit = nil } }
                }
            }
        }
        // Every position fits in the dock now: nothing left for the panel.
        .onChange(of: presets.count < places) { _, allFit in
            if allFit, showingAll { withAnimation(.snappy(duration: 0.3)) { model.morePositionsOpen = nil } }
        }
    }

    /// The positions that don't fit in the dock, as cards in a grid, and Keep.
    func others(_ rest: [PTZPreset]) -> some View {
        // Side by side, up to four; as cards come and go, it takes the width they need.
        let columns = min(4, rest.count + 1)
        // Exactly that many columns (an adaptive grid chose by the width it was offered, and stacked them).
        let grid = Array(repeating: GridItem(.fixed(Self.size.width), spacing: Self.spacing), count: columns)
        return ScrollView {
            LazyVGrid(columns: grid, alignment: .leading, spacing: 12) {
                ForEach(rest) { preset in
                    card(preset, from: .morePositions) {
                        withAnimation(.snappy(duration: 0.3)) { model.morePositionsOpen = nil }
                        go(preset)
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Button {
                    withAnimation(.snappy(duration: 0.3)) { model.morePositionsOpen = nil }
                    add()
                } label: { tile(symbol: "plus", title: "Keep") }
                    .buttonStyle(.plain)
                    .help("Keep where it points now as a position")
            }
            .padding(14)
        }
        // As wide as its cards need.
        .frame(width: CGFloat(columns) * (Self.size.width + Self.spacing) - Self.spacing + 28, alignment: .leading)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: rest.count < 12)
        .animation(.snappy(duration: 0.3), value: rest.map(\.id))

    }

    /// A position's card: a click goes there; dragged onto another, it takes that one's place.
    func card(_ preset: PTZPreset, from source: ReorderDrag.Source, action: @escaping () -> Void) -> some View {
        let key = "\(camera)/\(preset.id)"
        // Dimmed while dragged (in the dock), or a little while a card from the panel is over it.
        let dragged = drag.camera == key && drag.source == .positions
        let target = drag.over == key && drag.source == .morePositions && drag.camera != key
        return PresetCard(name: preset.name, picture: pictures[AppModel.presetKey(camera, preset.id)], action: action)
            .contextMenu { menu(preset) }
            .opacity(dragged ? 0.45 : target ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: dragged || target)
            .onDrag { drag.begin(key, from: source) } preview: { DragPreview(name: preset.name, symbol: "scope") }
            .onDrop(of: [.text], delegate: PresetDropDelegate(target: key, drag: drag) { moved, onto in
                move(String(moved.dropFirst(camera.count + 1)), String(onto.dropFirst(camera.count + 1)))
            })
    }

    /// The picture appears over More, drops into its middle and vanishes as the card clicks down and back.
    func dropIntoMore(_ picture: NSImage) {
        dropped = false
        withAnimation(.easeOut(duration: 0.14)) { dropping = picture }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.easeIn(duration: 0.32)) { dropped = true }
            try? await Task.sleep(for: .milliseconds(260))
            clickMore()
            try? await Task.sleep(for: .milliseconds(150))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                dropping = nil
                dropped = false
            }
        }
    }

    /// More pressed in and springing back.
    func clickMore() {
        Task {
            withAnimation(.easeOut(duration: 0.08)) { morePressed = true }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { morePressed = false }
        }
    }

    func tile(symbol: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3.weight(.semibold))
                .frame(width: Self.size.width, height: Self.size.height)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// A camera's other positions (those that don't fit in the dock), open above its More card: the card says
/// where it is and what to show; the dock draws it there, outside its own edges (which clip what's in them),
/// on glass with an arrow down to the card. Drawn in the window (not a popover, whose size AppKit animates on
/// its own), so the glass grows and shrinks with the cards in it.
struct MorePositions: PreferenceKey {
    struct Panel {
        let anchor: Anchor<CGRect>
        let content: AnyView
        /// What's in it, so a change in it animates.
        let ids: [String]
        /// Shown (the card says where it is all along, so only the panel comes and goes).
        let open: Bool
    }

    static var defaultValue: Panel? { nil }
    static func reduce(value: inout Panel?, nextValue: () -> Panel?) { value = nextValue() ?? value }
}

/// The open panel, drawn over the dock where its More card is: standing on the card's top edge (no measuring,
/// so it's in its place from its first frame), growing up out of the card as it opens.
struct MorePositionsPanel: View {
    let panel: MorePositions.Panel?
    let close: () -> Void
    static let arrow: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            if let panel {
                let card = proxy[panel.anchor]
                // A line just above the More card, the panel standing on it by its bottom edge.
                Color.clear
                    .frame(width: card.width, height: 0)
                    .overlay(alignment: .bottom) {
                        if panel.open {
                            panel.content
                                .padding(.bottom, Self.arrow)
                                .fixedSize()
                                .glassEffect(.regular, in: Callout(arrowX: 0, pointsDown: true, centred: true))
                                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                        }
                    }
                    // Placed by its centre (where a container puts what's in it doesn't matter then).
                    .position(x: card.midX, y: card.minY - 4)
            }
        }
        .animation(.snappy(duration: 0.3), value: panel?.ids)
    }
}

/// Where a dragged position lands: dragged within the dock, the others move out of its way as it goes (as the
/// rail's cameras do); from the panel of those that don't fit, it takes the place of the one it's dropped on.
/// Ids are "camera/position", so a camera's positions only take its own.
struct PresetDropDelegate: DropDelegate {
    let target: String
    let drag: ReorderDrag
    let move: (_ moved: String, _ onto: String) -> Void

    var sameCamera: Bool {
        guard let dragged = drag.camera else { return false }
        return dragged.split(separator: "/").first == target.split(separator: "/").first
    }

    func validateDrop(info: DropInfo) -> Bool { sameCamera }

    func dropEntered(info: DropInfo) {
        guard sameCamera else { return }
        drag.over = target
        if drag.source == .positions { drag.moveIfSettled(move) }
    }

    func dropExited(info: DropInfo) {
        if drag.over == target { drag.over = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if drag.source == .positions { drag.moveIfSettled(move) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if drag.source == .morePositions, let moved = drag.camera, moved != target { move(moved, target) }
        drag.camera = nil
        drag.source = nil
        drag.over = nil
        return true
    }
}

/// Moved, scaled and faded: a transition's two ends.
struct Displaced: ViewModifier {
    let x: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.scaleEffect(scale).offset(x: x).opacity(opacity)
    }
}

/// One position: its picture and name, lit under the pointer.
struct PresetCard: View {
    let name: String
    let picture: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let picture {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "scope").font(.title3).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.06))
                    }
                }
                .frame(width: PresetCards<EmptyView>.size.width, height: PresetCards<EmptyView>.size.height)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(hovering ? 0.55 : 0.12), lineWidth: hovering ? 2 : 1)
                }
                .scaleEffect(hovering ? 1.03 : 1)
                Text(name).font(.caption.weight(.medium)).lineLimit(1)
                    .frame(width: PresetCards<EmptyView>.size.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Go to \u{201C}\(name)\u{201D}")
    }
}

// MARK: - The dock

/// A camera's controls, under it on the stage, laid out like a remote: the move pad in the middle, its kept
/// positions to one side, day and night (and zoom) to the other, at the same spacing whatever the window's
/// width; narrower, the sides stack beside the pad, then the positions go to a menu. Another camera's controls
/// crossfade in, in the same panel.
struct LiveControlsDock: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let controls: Config.Controls
    /// Shown (not slid away): only then does it ask the cameras' rail for room.
    var open = true
    @State private var mover = PTZMover()
    /// The camera shown, which follows `camera` a moment later, in an update of its own (the stage switches
    /// cameras without animation, which would otherwise swap the controls at once): so they crossfade.
    @State private var shown: (camera: Config.Camera, controls: Config.Controls)?

    /// The most positions' cards across (Keep or More included); more positions go to More.
    nonisolated static let positionColumns = 4
    /// Each side's widest: the positions' cards at their most.
    nonisolated static let sideWidth: CGFloat = CGFloat(positionColumns) * (88 + 10) - 10 + 8
    nonisolated static let spacing: CGFloat = 24
    /// The left side without positions (home, tours, zoom).
    nonisolated static let movingWidth: CGFloat = 140
    /// The main row's height; the dock's, the same however its adjustments are shown (beside it, or in a
    /// sidebar), so the picture above keeps its height.
    nonisolated static let mainHeight: CGFloat = 132
    nonisolated static func height(adjusting: Bool = false) -> CGFloat { 32 + mainHeight }
    /// Its widest (each side at its widest).
    nonisolated static let width: CGFloat = 2 * sideWidth + 124 + 2 * spacing + 48

    /// The left side's width: the positions' cards as many across as they need (up to `sideWidth`); the right
    /// side is as wide as the everyday controls. Each only as wide as what's in it: the pad stays about in the
    /// middle, without empty room beside a few cards or before the dock's edge.
    func side(for controls: Config.Controls, camera: String) -> CGFloat {
        let cards = (controls.ptz?.presets ?? 0) > 0 ? model.orderedPresets(camera).count + 1 : 0
        let columns = min(cards, Self.positionColumns)
        let positions = columns == 0 ? 0
            : CGFloat(columns) * (PresetCards<EmptyView>.size.width + PresetCards<EmptyView>.spacing) - PresetCards<EmptyView>.spacing + 8
        // Without positions, room for home, tours and zoom.
        return positions > 0 ? positions : Self.movingWidth
    }

    /// The dock's width for this camera in the full arrangement.
    func width(for controls: Config.Controls, camera: String) -> CGFloat {
        controls.ptz == nil ? everydayWidth + insets(controls)
            : side(for: controls, camera: camera) + 124 + 2 * Self.spacing + everydayWidth + insets(controls)
    }

    /// What's around its controls: its padding, and the adjustments' edge (beside which the padding is less, the
    /// edge itself being room enough). Narrow, less padding.
    func insets(_ controls: Config.Controls, narrow: Bool = false) -> CGFloat {
        let adjustable = !DockContents.adjustments(controls).isEmpty
        let leading: CGFloat = narrow ? 16 : 24
        return leading + (adjustable ? 16 + Self.sidebarButton + 1 : leading)
    }

    /// Its controls' width in an arrangement (as they lay themselves out, measured), without what's around them.
    func contentWidth(_ arrangement: Arrangement, controls: Config.Controls, camera: String) -> CGFloat {
        if controls.ptz == nil { return everydayWidth }
        return switch arrangement {
        case .full: width(for: controls, camera: camera) - insets(controls)
        case .beside: besideWidth
        case .narrow: narrowWidth
        }
    }

    /// The dock's width in an arrangement: as narrow as its controls allow.
    func width(_ arrangement: Arrangement, controls: Config.Controls, camera: String) -> CGFloat {
        let content = contentWidth(arrangement, controls: controls, camera: camera)
        // Narrowest, room for its adjustments' own frame too (they may slide in there).
        let adjustments = arrangement == .narrow && !DockContents.adjustments(controls).isEmpty ? Self.adjustmentsWidth : 0
        return max(content, adjustments) + insets(controls, narrow: arrangement == .narrow)
    }

    /// The adjustments' frame (a narrow window): its own width, two columns of sliders with their names, however
    /// narrow the camera's controls are (the dock widens to it as it slides).
    nonisolated static let adjustmentsWidth: CGFloat = 460

    /// The widest arrangement that fits.
    func fitting(controls: Config.Controls, camera: String) -> Arrangement {
        if available >= width(.full, controls: controls, camera: camera) { return .full }
        if available >= width(.beside, controls: controls, camera: camera) { return .beside }
        return .narrow
    }

    /// How wide its narrower arrangements' controls are (measured, as the everyday controls are).
    @State private var besideWidth: CGFloat = 470
    @State private var narrowWidth: CGFloat = 330

    /// The strip down its right edge that opens the adjustments' sidebar.
    nonisolated static let sidebarButton: CGFloat = 44
    /// The strip's name, shown beside the dock while the pointer rests on it.
    @State private var edgeLabel = false
    /// About how wide the name is, to tell whether it fits beside the dock.
    nonisolated static let edgeLabelWidth: CGFloat = 112

    /// How wide its everyday controls are (measured), for its sides.
    @State private var everydayWidth: CGFloat = 230

    /// Its arrangements, widest first: chosen by width (each measured as it lays itself out), so a change
    /// between them can crossfade. Narrower than the narrowest, its controls are scaled down to fit: they never
    /// go past its edges.
    enum Arrangement: Equatable {
        case full, beside, narrow
    }

    @State private var arrangement = Arrangement.full
    @State private var available = LiveControlsDock.width
    /// The adjustments shown (kept between launches; the live view sizes the dock's place by it too).
    @AppStorage(LiveControlsDock.adjustingKey) private var adjusting = false
    nonisolated static let adjustingKey = "dockAdjusting"
    @AppStorage(LiveView.railKey) private var showRail = true
    /// It has been on screen a moment: until then, arrangements are taken at once as its controls are measured
    /// (not crossfaded, which shifted the dock as it opened).
    @State private var measured = false
    /// The sidebar is coming or going: the dock's room changes with it.
    @State private var withSidebar = false
    /// The adjustments open or not, as last seen: a change of it is the person's (animated); else the
    /// window's size moved them (at once).
    @State private var lastAdjusting: Bool?
    /// The film strip on its adjustments frame: the dock's own, animated only when the edge is clicked (kept
    /// in step with `adjusting` at once otherwise: the window resized, a launch). The stored preference's
    /// change comes apart from the click's animation, and an animation keyed to it slid the frames as the
    /// window was resized.
    @State private var filmAdjusting = false

    /// The edge clicked: the adjustments opened or closed, the film sliding along with it.
    func toggleAdjustments() {
        let next = !adjusting
        withAnimation(LiveView.dockAnimation) { filmAdjusting = next }
        adjusting = next
    }

    var current: (camera: Config.Camera, controls: Config.Controls) { shown ?? (camera, controls) }

    var body: some View {
        // The room it's given, measured by something that takes only that (the dock is drawn over it, so its
        // own width never pushes the window's layout wider), choosing the arrangement that fits.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.height())
            // Narrowed or widened by the sidebar coming or going: with it (rather than at once, the room it's
            // given being its final width straight away). A window being resized is followed as it is.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if withSidebar {
                    withAnimation(LiveView.dockAnimation) { available = width }
                } else {
                    available = width
                }
            }
            .onChange(of: fitting(controls: current.controls, camera: current.camera.id), initial: true) { _, fitting in
                if measured {
                    withAnimation(withSidebar ? LiveView.dockAnimation : .easeInOut(duration: 0.25)) { arrangement = fitting }
                } else {
                    arrangement = fitting
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(0.4))
                measured = true
            }
            .onChange(of: available) { _, width in fitRail(width) }
            .onChange(of: width(.narrow, controls: current.controls, camera: current.camera.id), initial: true) { _, narrowest in
                if abs(model.dockNarrowest - narrowest) > 1 { model.dockNarrowest = narrowest }
            }
            .onChange(of: open) { fitRail(available) }
            .onDisappear {
                model.railLimit = nil
                // Gone (several cameras on the stage): the rail it hid for room comes back (its button is off
                // meanwhile).
                if model.railMadeRoom {
                    withAnimation(LiveView.dockAnimation) { showRail = true }
                    model.railMadeRoom = false
                }
            }
            .overlay { withAdjustments }
            .onAppear { shown = (camera, controls) }
            // The same camera's controls changed (identified again): kept up, without a fade.
            .onChange(of: controls) { if shown?.camera.id == camera.id { shown = (camera, controls) } }
            .onChange(of: camera.id) {
                closeMore()
                mover.set(PTZVelocity(), camera: current.camera.id, model: model)
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.3)) { shown = (camera, controls) }
                }
            }
    }

    /// The dock; its adjustments, when open, are in the live view's sidebar.
    var withAdjustments: some View {
        dock
            .onChange(of: adjusting && !DockContents.adjustments(current.controls).isEmpty && !filming, initial: true) { _, open in
                // Opened or closed by hand (animated), or moved by the window's size between the sidebar and the
                // dock (at once, as the window is resized), or there from the start.
                let asked = lastAdjusting != nil && adjusting != lastAdjusting
                lastAdjusting = adjusting
                guard model.adjustmentsInSidebar != open else { return }
                guard asked else {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { model.adjustmentsInSidebar = open }
                    fitRail(available)
                    return
                }
                withSidebar = true
                // No room beside the sidebar for even the narrowest dock: the cameras' rail makes room. It comes
                // back with the sidebar's going only if there's room for it then (checked once it has gone).
                if open, showRail, !model.sidebarFloats,
                   available - LiveView.sidebarRoom < width(.narrow, controls: current.controls, camera: current.camera.id) {
                    withAnimation(LiveView.dockAnimation) { showRail = false }
                    model.railMadeRoom = true
                }
                withAnimation(LiveView.dockAnimation) { model.adjustmentsInSidebar = open }
                Task {
                    try? await Task.sleep(for: .seconds(0.6))
                    withSidebar = false
                    fitRail(available)
                }
            }
            .onDisappear { model.adjustmentsInSidebar = false }
            .onChange(of: adjusting, initial: true) { _, open in
                guard filmAdjusting != open else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { filmAdjusting = open }
            }
    }

    var dock: some View {
        let (camera, controls) = current
        // One camera's controls, crossfading as a whole when the camera changes.
        let adjustable = !DockContents.adjustments(controls).isEmpty
        let narrow = arrangement == .narrow
        let natural = contentWidth(arrangement, controls: controls, camera: camera.id)
        let insets = insets(controls, narrow: narrow)
        // Too narrow even for the narrowest, with the rail out of the way: the whole dock smaller (its glass with
        // its controls), never past its edges. Rare: the rail makes room first.
        // (Not while the rail is still there: it steps aside first, and the dock shrunk for that moment
        // was seen growing back.)
        let framedWidth = max(natural, Self.adjustmentsWidth)
        let scale = showRail && open ? 1 : min(1, max(0.1, available / ((filming && filmAdjusting ? framedWidth : natural) + insets)))
        // In a narrow window, the adjustments are the second frame of a film strip, the edge between the two
        // frames: shown, the whole strip moves along one frame, as one surface (the controls out to the left,
        // the edge with them to the dock's left side, the adjustments in from the right).
        let framed = filming && filmAdjusting
        let plain: CGFloat = narrow ? 16 : 24
        // As wide as the frame in view: the controls', or the adjustments' own.
        let visible = (framed ? framedWidth : natural) + insets
        return HStack(spacing: 0) {
            ZStack {
                DockContents(camera: camera, controls: controls, arrangement: arrangement,
                             left: side(for: controls, camera: camera.id), right: everydayWidth, mover: mover,
                             measured: { kind, width in measured(kind, width) })
                    .id(camera.id)
                    .transition(.opacity)
            }
            // New when the film begins or ends (the window resized), at once: a crossfade between its own
            // arrangements, still going, was left fading where the controls had been, over the adjustments.
            .id(filming)
            .frame(width: natural)
            .padding(.leading, plain)
            .padding(.trailing, adjustable ? 16 : plain)
            .padding(.vertical, 16)
            // Its edge opens the adjustments (beside the stage, or the strip's next frame): part of the dock,
            // frosted, a hairline from each frame.
            if adjustable {
                AdjustEdge(open: adjusting, toggle: toggleAdjustments, label: $edgeLabel, mirrored: framed)
                    .frame(width: Self.sidebarButton + 1)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
                    .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(filming ? 0.1 : 0)).frame(width: 1) }
                    // Always over the frames beside it: a layout fading out as the dock morphs was drawn above it.
                    .zIndex(1)
            }
            if filming {
                DockAdjustments(camera: camera, controls: controls, width: framedWidth, trailing: plain)
                    .frame(height: Self.height())
            }
        }
        .offset(x: framed ? -(plain + natural + 16) : 0)
        .frame(width: visible, alignment: .leading)
        .frame(height: Self.height())
        // Inside the glass: what fades out as something else comes in stays within the panel's edges.
        .clipShape(.rect(cornerRadius: 26))
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        // Its size changing, the glass and its edge (the adjustments' strip) as one surface: animated outside
        // both (inside, the controls and strip moved while the glass took its new size at once).
        .animation(LiveView.dockAnimation, value: natural)
        .animation(LiveView.dockAnimation, value: narrow)
        .scaleEffect(scale)
        // The right edge's name while the pointer rests there: just outside it, or, with no room beside the
        // dock (a narrow window), just above it.
        .overlay(alignment: framed ? .topLeading : .topTrailing) {
            let beside = (available - min(available, width(arrangement, controls: controls, camera: camera.id))) / 2 + 12 >= Self.edgeLabelWidth + 16
            Text(framed ? "Controls" : "Adjustments")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                // (Glass shows through a zero opacity: none while it's hidden.)
                .glassEffect(edgeLabel ? .regular : .identity, in: .capsule)
                .fixedSize()
                // By its width, not its other edge (which the guide beside it redefines: the name mirrored for the
                // edge on the left sat over the edge).
                .alignmentGuide(.trailing) { beside ? -10 : $0.width }
                // (The edge on the left: to its left, or above its left end.)
                .alignmentGuide(.leading) { beside ? $0.width + 10 : 0 }
                .alignmentGuide(.top) { beside ? $0[VerticalAlignment.center] - Self.height() / 2 : $0[.bottom] + 8 }
                .opacity(edgeLabel ? 1 : 0)
                .scaleEffect(edgeLabel ? 1 : 0.92, anchor: beside ? (framed ? .trailing : .leading) : (framed ? .bottomLeading : .bottomTrailing))
                .animation(.easeOut(duration: 0.15), value: edgeLabel)
                .allowsHitTesting(false)
        }
        // A camera's other positions, open above its More card (outside the dock's edges, so after its clipping).
        .overlayPreferenceValue(MorePositions.self) { panel in
            MorePositionsPanel(panel: panel) { closeMore() }
        }
        .overlay(alignment: .bottom) {
            if let saved = model.savedPicture, saved.camera == camera.id, model.controlError[camera.id] == nil {
                // The whole bubble shows it in Finder.
                Button { NSWorkspace.shared.activateFileViewerSelecting([saved.file]) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Saved to Pictures \u{203A} Pond").font(.caption)
                        Text("Show").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help("Show the picture in Finder")
                .offset(y: 12)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        // What went wrong, just above its left corner (clear of its controls and the window's edge); frosted
        // rather than glass, which doesn't fade.
        .overlay(alignment: .topLeading) {
            ZStack {
                if let error = model.controlError[camera.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 10 }
            .padding(.leading, 12)
        }
        .animation(.easeOut(duration: 0.2), value: model.controlError[camera.id])
        .animation(.easeOut(duration: 0.2), value: model.savedPicture?.file)
        .task(id: camera.id) {
            if (controls.ptz?.presets ?? 0) > 0 {
                // Their pictures from disk at once, then the camera's list.
                model.loadPresetPictures(camera.id, AppModel.keptPresets(camera.id))
                await model.loadPresets(camera.id)
            }
            if !controls.items.isEmpty { await model.loadItemValues(camera.id) }
        }
        // Arrow keys move it while the dock has the keyboard.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .up]) { press in
            guard controls.ptz?.panTilt == true else { return .ignored }
            if press.phase == .up {
                mover.set(PTZVelocity(), camera: camera.id, model: model)
                return .handled
            }
            let v: PTZVelocity = switch press.key {
            case .upArrow: PTZVelocity(tilt: 0.6)
            case .downArrow: PTZVelocity(tilt: -0.6)
            case .leftArrow: PTZVelocity(pan: -0.6)
            default: PTZVelocity(pan: 0.6)
            }
            mover.set(v, camera: camera.id, model: model)
            return .handled
        }
        .onDisappear {
            mover.set(PTZVelocity(), camera: camera.id, model: model)
            model.morePositionsOpen = nil
        }
        .onKeyPress(.escape) {
            guard model.morePositionsOpen != nil else { return .ignored }
            closeMore()
            return .handled
        }
    }

    /// The cameras' rail and the open dock side by side: the window made too narrow for the dock's narrowest,
    /// the rail makes room (as when the sidebar opens), and comes back once there's room again (or the dock
    /// closes). The rail can't be dragged wider than leaves the dock room.
    func fitRail(_ width: CGFloat) {
        let narrowest = self.width(.narrow, controls: current.controls, camera: current.camera.id)
        let limit: CGFloat? = open && showRail ? model.railWidth + width - narrowest : nil
        if model.railLimit != limit { model.railLimit = limit }
        if model.railMadeRoom, !showRail, !withSidebar, !open || width - model.railWidth - LiveView.railGap >= narrowest + 8 {
            withAnimation(LiveView.dockAnimation) { showRail = true }
            model.railMadeRoom = false
            return
        }
        guard open, showRail, !withSidebar, width < narrowest else { return }
        withAnimation(LiveView.dockAnimation) { showRail = false }
        model.railMadeRoom = true
    }

    /// The adjustments are a frame of the dock (a window too narrow for them beside the stage).
    var filming: Bool {
        model.sidebarFloats && !DockContents.adjustments(current.controls).isEmpty
    }

    /// Its controls' widths, as they lay themselves out.
    func measured(_ kind: DockContents.Measure, _ width: CGFloat) {
        let width = width.rounded(.up)
        switch kind {
        case .everyday: if abs(width - everydayWidth) > 1 { everydayWidth = width }
        case .beside: if abs(width - besideWidth) > 1 { besideWidth = width }
        case .narrow: if abs(width - narrowWidth) > 1 { narrowWidth = width }
        }
    }

    func closeMore() {
        if model.morePositionsOpen != nil { withAnimation(.snappy(duration: 0.3)) { model.morePositionsOpen = nil } }
    }
}

/// One camera's controls in the dock, in the arrangement that fits.
struct DockContents: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let controls: Config.Controls
    let arrangement: LiveControlsDock.Arrangement
    /// Each side's width in the full arrangement: the positions' (left), the everyday controls' (right).
    let left: CGFloat
    let right: CGFloat
    let mover: PTZMover
    /// Told how wide each way of laying them out is, for the dock to choose and size itself.
    var measured: (Measure, CGFloat) -> Void = { _, _ in }

    enum Measure { case everyday, beside, narrow }
    @AppStorage(LiveControlsDock.adjustingKey) private var adjusting = false
    @State private var naming = false
    @State private var newName = ""

    /// The items with a place of their own in the main row, the same for every camera; everything else is an
    /// adjustment (image settings, setting home, relays, and whatever a make's provider adds).
    static func inMainRow(_ item: Config.Controls.Item) -> Bool {
        ["dayNight", "speakerVolume", "home.go"].contains(item.id) || item.id.hasPrefix("tour.")
    }

    static func adjustments(_ controls: Config.Controls) -> [Config.Controls.Item] {
        controls.items.filter { !inMainRow($0) }
    }

    var body: some View {
        main
            .frame(height: LiveControlsDock.mainHeight)
            // Each way of laying them out, measured unseen (so the dock knows which fits before choosing it).
            .background {
                ZStack {
                    everyday.fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured(.everyday, $0) }
                    if controls.ptz != nil {
                        compact(narrow: false, measuring: true).fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured(.beside, $0) }
                        compact(narrow: true, measuring: true).fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured(.narrow, $0) }
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    func item(_ id: String) -> Config.Controls.Item? { controls.items.first { $0.id == id } }

    // MARK: Main row

    /// Moving it (left), the pad (middle), what's used most (right): equal sides, so the pad stays in the
    /// middle; without PTZ, just the right side, in the middle.
    @ViewBuilder var main: some View {
        if controls.ptz == nil {
            everyday
        } else {
            switch arrangement {
            case .full:
                HStack(alignment: .center, spacing: LiveControlsDock.spacing) {
                    moving(width: left).frame(width: left, alignment: .leading)
                    pad
                    everyday.fixedSize().frame(width: right, alignment: .leading)
                }
                .transition(.opacity)
            case .beside:
                compact(narrow: false, measuring: false).fixedSize().transition(.opacity)
            case .narrow:
                compact(narrow: true, measuring: false).fixedSize().transition(.opacity)
            }
        }
    }

    /// Narrower: the pad, and beside it what's used most, with the positions as a menu on the second row
    /// (the shorter one). Narrowest, the same with the menu an icon and the speaker's slider shorter.
    func compact(narrow: Bool, measuring: Bool) -> some View {
        HStack(alignment: .center, spacing: narrow ? 16 : 20) {
            pad
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    if let day = item("dayNight") { ItemView(camera: camera, item: day) }
                    picture
                    privacy
                }
                HStack(alignment: .top, spacing: 16) {
                    ControlSection(title: "Positions") { positionsMenu(iconOnly: narrow, measuring: measuring) }
                    talk
                    if let volume = item("speakerVolume") {
                        ControlSection(title: volume.title) { SliderItem(camera: camera, item: volume, compact: true, sliderWidth: narrow ? 104 : 120) }
                    }
                    moveActions
                }
            }
        }
    }

    /// Positions, and under them home, tours and zoom.
    func moving(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            positions(width: width)
            HStack(alignment: .top, spacing: 16) {
                moveActions
                zoom
            }
        }
    }

    /// Home and tours.
    @ViewBuilder var moveActions: some View {
        if let home = item("home.go") { ItemView(camera: camera, item: home) }
        ForEach(controls.items.filter { $0.id.hasPrefix("tour.") }) { tour in ItemView(camera: camera, item: tour) }
    }

    /// What's used most, always in the same places: day and night, a picture of it and its privacy; talking
    /// and how loud.
    var everyday: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                if let day = item("dayNight") { ItemView(camera: camera, item: day) }
                picture
                privacy
            }
            HStack(alignment: .top, spacing: 18) {
                talk
                if let volume = item("speakerVolume") {
                    ControlSection(title: volume.title) { SliderItem(camera: camera, item: volume, compact: true) }
                }
            }
        }
    }

    /// Talking through its speaker (as the tile's button).
    @ViewBuilder var talk: some View {
        if controls.talk != nil {
            ControlSection(title: "Talk") {
                // (The dock shows what went wrong itself.)
                TalkButton(camera: camera, showsErrors: false).frame(height: 38)
            }
        }
    }

    /// The move pad; without pan and tilt, an empty place of its size, so the sides stay put.
    @ViewBuilder var pad: some View {
        if let ptz = controls.ptz, ptz.panTilt {
            DirectionPad(size: 124) { v in mover.set(PTZVelocity(pan: v.dx, tilt: v.dy), camera: camera.id, model: model) }
        } else {
            Color.clear.frame(width: 1, height: 124)
        }
    }

    @ViewBuilder var zoom: some View {
        if let ptz = controls.ptz, ptz.zoom {
            ControlSection(title: "Zoom") {
                HStack(spacing: 10) {
                    HoldButton(systemImage: "minus.magnifyingglass", help: "Zoom out",
                               began: { mover.set(PTZVelocity(zoom: -0.6), camera: camera.id, model: model) },
                               ended: { mover.set(PTZVelocity(), camera: camera.id, model: model) })
                    HoldButton(systemImage: "plus.magnifyingglass", help: "Zoom in",
                               began: { mover.set(PTZVelocity(zoom: 0.6), camera: camera.id, model: model) },
                               ended: { mover.set(PTZVelocity(), camera: camera.id, model: model) })
                }
            }
        }
    }

    @ViewBuilder func positions(width: CGFloat) -> some View {
        if let ptz = controls.ptz, ptz.presets > 0 {
            ControlSection(title: "Positions") {
                PresetCards(camera: camera.id, presets: model.orderedPresets(camera.id),
                            pictures: model.presetPictures,
                            move: { model.movePreset(camera.id, $0, to: $1) },
                            go: { preset in Task { await model.goTo(camera.id, preset: preset.id) } },
                            menu: { preset in presetMenu(preset) },
                            add: { newName = ""; naming = true },
                            naming: $naming, namer: AnyView(namer))
                    .frame(maxWidth: width, alignment: .leading)
            }
        }
    }

    /// The positions in a menu, for a narrow window.
    @ViewBuilder func positionsMenu(iconOnly: Bool, measuring: Bool) -> some View {
        if let ptz = controls.ptz, ptz.presets > 0 {
            let menu = Menu {
                ForEach(model.presets[camera.id] ?? []) { preset in
                    Button(preset.name) { Task { await model.goTo(camera.id, preset: preset.id) } }
                }
                Divider()
                Button("Keep Where It Points Now\u{2026}") { newName = ""; naming = true }
            } label: {
                // As tall as the talk button beside it.
                Group {
                    if iconOnly { Image(systemName: "scope") } else { Label("Positions", systemImage: "scope") }
                }
                .font(.system(size: 13, weight: .semibold))
                .frame(height: CameraTile.pillHeight - 8)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .frame(height: 38)
            .fixedSize()
            .help("Positions")
            // (Its unseen copies, measured, without the namer.)
            if measuring { menu } else { menu.popover(isPresented: $naming, arrowEdge: .top) { namer } }
        }
    }

    @ViewBuilder func presetMenu(_ preset: PTZPreset) -> some View {
        Button("Keep Where It Points Now") {
            Task { await model.savePreset(camera.id, name: preset.name, replacing: preset.id) }
        }
        Divider()
        Button("Remove \u{201C}\(preset.name)\u{201D}", role: .destructive) {
            Task { await model.removePreset(camera.id, preset: preset.id) }
        }
    }

    var namer: some View {
        HStack {
            TextField("Position name", text: $newName, prompt: Text("Front door"))
                .frame(width: 180)
                .onSubmit(save)
            Button("Keep", action: save).keyboardShortcut(.defaultAction).disabled(newName.isEmpty)
        }
        .padding(12)
    }

    /// A picture of what it shows now, saved to Pictures/Pond.
    var picture: some View {
        ControlSection(title: "Picture") {
            Button { model.takePicture(camera) } label: {
                Image(systemName: "camera.fill").font(.system(size: 16, weight: .semibold))
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .help("Save a picture of what \(camera.name) shows now (to Pictures › Pond)")
            // Private: there's no picture to save.
            .disabled(model.isPrivate(camera.id))
        }
    }

    /// Pond's privacy for the camera: lit while it's private (not recorded, shown live or in the Home app).
    var privacy: some View {
        let on = model.isPrivate(camera.id)
        // On the camera itself: lit, but Pond can't turn it off.
        let onCameraOnly = model.isPrivateOnCameraOnly(camera.id)
        let label = Image(systemName: on ? "eye.slash.fill" : "eye")
            .font(.system(size: 16, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 34)
        let toggle = { Task { await model.setPrivacy(camera.id, !on) } }
        return ControlSection(title: "Privacy") {
            Group {
                if on {
                    Button { _ = toggle() } label: { label }.buttonStyle(.glassProminent)
                } else {
                    Button { _ = toggle() } label: { label }.buttonStyle(.glass)
                }
            }
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(onCameraOnly)
            .help(onCameraOnly ? "Its own privacy mode is on: turn it off in \(camera.device?.appName ?? "the camera\u{2019}s own app")"
                  : on ? "Turn privacy off: record and show \(camera.name) again"
                  : "Make \(camera.name) private: not recorded, shown live or in the Home app")
        }
    }

    func save() {
        guard !newName.isEmpty else { return }
        naming = false
        let name = newName
        Task { await model.savePreset(camera.id, name: name) }
    }
}

/// A camera's adjustments (everything without a place in the dock's main row), in the live view's sidebar
/// down the right (as the rail is down the left, so the picture keeps its height): the groups one under
/// another.
struct AdjustmentsView: View {
    let camera: Config.Camera
    let controls: Config.Controls

    var groups: [(Config.Controls.Item.Group, [Config.Controls.Item])] {
        let all = DockContents.adjustments(controls)
        return Config.Controls.Item.Group.allCases.compactMap { group in
            let items = all.filter { $0.group == group }.sorted { $0.order < $1.order }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Adjustments").font(.headline)
                // A hairline between groups, each under its own heading (not like a control's name).
                ForEach(Array(groups.enumerated()), id: \.element.0) { index, entry in
                    if index > 0 { Divider().opacity(0.6) }
                    section(entry.0, entry.1)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    /// A group: its buttons, then its sliders one under another, each with its name and value above it.
    func section(_ group: Config.Controls.Item.Group, _ items: [Config.Controls.Item]) -> some View {
        let sliders = items.filter { if case .slider = $0.kind { true } else { false } }
        let others = items.filter { if case .slider = $0.kind { false } else { true } }
        return VStack(alignment: .leading, spacing: 14) {
            GroupHeading(group: group)
            VStack(alignment: .leading, spacing: 18) {
                if !others.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(others) { item in ItemView(camera: camera, item: item) }
                    }
                }
                ForEach(sliders) { item in SliderItem(camera: camera, item: item, stacked: true) }
            }
        }
    }
}

/// The adjustments as the dock's second frame (a narrow window), a page per group: a column of the groups
/// against the dock's edge (one frosted surface with it), the chosen one's page beside it. Pages are stacked,
/// and choosing a group slides to its page: across is controls or adjustments, down is which adjustments.
struct DockAdjustments: View {
    let camera: Config.Camera
    let controls: Config.Controls
    /// Its width without the group column (the dock's controls' width), and the dock's padding on its right.
    let width: CGFloat
    let trailing: CGFloat
    @State private var page: Config.Controls.Item.Group?
    /// Under the pointer, and named (after a moment's rest).
    @State private var hovered: Config.Controls.Item.Group?
    @State private var named: Config.Controls.Item.Group?
    @State private var naming: Task<Void, Never>?

    static let columnWidth: CGFloat = 40

    func hover(_ group: Config.Controls.Item.Group, _ inside: Bool) {
        naming?.cancel()
        if inside {
            hovered = group
            naming = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { named = group }
            }
        } else if hovered == group {
            hovered = nil
            named = nil
        }
    }

    var body: some View {
        let groups = AdjustmentsView(camera: camera, controls: controls).groups
        let current = page.flatMap { chosen in groups.firstIndex { $0.0 == chosen } } ?? 0
        let paged = groups.count > 1
        let pageHeight = LiveControlsDock.mainHeight
        HStack(spacing: 0) {
            if paged {
                VStack(spacing: 4) {
                    ForEach(Array(groups.enumerated()), id: \.element.0) { index, entry in
                        let chosen = index == current, under = hovered == entry.0
                        Image(systemName: entry.0.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(under ? .primary : .secondary))
                            .frame(width: 30, height: 28)
                            .background(chosen ? Color.accentColor.opacity(0.18) : under ? .white.opacity(0.08) : .clear,
                                        in: .rect(cornerRadius: 8))
                            .animation(.easeOut(duration: 0.15), value: under)
                            .contentShape(.rect)
                            .onTapGesture {
                                naming?.cancel()
                                named = nil
                                withAnimation(LiveView.dockAnimation) { page = entry.0 }
                            }
                            .onHover { inside in hover(entry.0, inside) }
                            // Its name beside it after a moment's rest (sooner than a tooltip), over the page.
                            .overlay(alignment: .leading) {
                                Text(entry.0.title)
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .glassEffect(named == entry.0 ? .regular : .identity, in: .capsule)
                                    .fixedSize()
                                    .offset(x: 36)
                                    .opacity(named == entry.0 ? 1 : 0)
                                    .animation(.easeOut(duration: 0.15), value: named)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityElement()
                            .accessibilityLabel(entry.0.title)
                            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .frame(width: Self.columnWidth)
                .frame(maxHeight: .infinity)
                // (Over the pages, for its names.)
                .zIndex(1)
                // Darker than the pages beside it, so the column reads as the dock's chrome, not its content.
                .background(.ultraThinMaterial)
                .background(.black.opacity(0.28))
                .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
            }
            VStack(spacing: 0) {
                ForEach(groups, id: \.0) { group, items in
                    pageView(group, items)
                        .frame(height: pageHeight, alignment: .top)
                }
            }
            .offset(y: -CGFloat(current) * pageHeight)
            .frame(width: width - (paged ? Self.columnWidth : 0), height: pageHeight, alignment: .top)
            .clipped()
            .padding(.leading, 16)
            .padding(.trailing, trailing)
            .padding(.vertical, 16)
        }
    }

    /// One group: its switches, choices and actions in a row, its sliders two across.
    func pageView(_ group: Config.Controls.Item.Group, _ items: [Config.Controls.Item]) -> some View {
        let sliders = items.filter { if case .slider = $0.kind { true } else { false } }
        let others = items.filter { if case .slider = $0.kind { false } else { true } }
        return VStack(alignment: .leading, spacing: 10) {
            GroupHeading(group: group)
            VStack(alignment: .leading, spacing: 10) {
                if !others.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(others) { item in ItemView(camera: camera, item: item) }
                    }
                }
                if !sliders.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(sliders) { item in SliderItem(camera: camera, item: item, stacked: true) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dock's right edge, opening the adjustments' sidebar: a strip of the dock's own glass (its rounded
/// corners are the dock's), lit under the pointer and tinted while the sidebar is open. Resting on it names
/// it, beside the dock, sooner than a tooltip would.
struct AdjustEdge: View {
    let open: Bool
    let toggle: () -> Void
    @Binding var label: Bool
    /// On the dock's left (the adjustments its frame): the icon facing the other way. Mirrored, not another
    /// symbol, so it travels with the edge (a new symbol was drawn where it would end up at once).
    var mirrored = false
    @State private var hovering = false
    @State private var naming: Task<Void, Never>?

    var body: some View {
        // Not a Button: a pressed button's label was drawn at its new place at once, while the dock's frames
        // slid (it teleported across); this moves with them.
        Image(systemName: "sidebar.right")
            .font(.system(size: 15, weight: .semibold))
            .scaleEffect(x: mirrored ? -1 : 1)
            .foregroundStyle(open ? AnyShapeStyle(.tint) : AnyShapeStyle(hovering ? .primary : .secondary))
            .frame(width: LiveControlsDock.sidebarButton)
            .frame(maxHeight: .infinity)
            .background {
                // Only the hover's tint eases on its own (the pointer leaves it as it slides away).
                (open ? Color.accentColor.opacity(0.18) : hovering ? .white.opacity(0.07) : .clear)
                    .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: clicked)
            // (Opening it has the dock's own animation: one of its own here re-timed the edge's slide with the
            // dock's frames, and its tint arrived first.)
            .onHover { inside in
                hovering = inside
                naming?.cancel()
                if inside {
                    naming = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { label = true }
                    }
                } else {
                    label = false
                }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, clicked)
            .accessibilityLabel(open ? "Hide Adjustments" : "Adjustments")
    }

    func clicked() {
        // Named until used.
        naming?.cancel()
        label = false
        toggle()
    }
}

/// A group's items, laid out the same way for every camera: its switches, choices and actions in a row (with
/// `leading` first), then its sliders in columns.
struct ItemsPanel<Leading: View, Trailing: View>: View {
    let camera: Config.Camera
    let items: [Config.Controls.Item]
    @ViewBuilder var leading: Leading
    /// After its switches, choices and actions (before the sliders).
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let sliders = items.filter { if case .slider = $0.kind { true } else { false } }
        let others = items.filter { if case .slider = $0.kind { false } else { true } }
        HStack(alignment: .center, spacing: 32) {
            HStack(alignment: .top, spacing: 18) {
                leading
                ForEach(others) { item in ItemView(camera: camera, item: item) }
                trailing
            }
            if !sliders.isEmpty {
                // Two columns when there are more than two.
                let columns = sliders.count > 2 ? 2 : 1
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: sliders.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(sliders[start ..< min(start + columns, sliders.count)]) { item in
                                SliderItem(camera: camera, item: item)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}

/// One item, drawn as its kind: a choice of icons, a switch, or a button (asking first, if it says to).
struct ItemView: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let item: Config.Controls.Item
    @State private var confirming = false

    var value: Config.Controls.Value? { model.itemValues[camera.id]?[item.id] }

    var body: some View {
        ControlSection(title: item.title) {
            switch item.kind {
            case let .choice(choices):
                IconChoice(options: choices.map { .init(value: $0.value, title: $0.title, systemImage: $0.symbol) },
                           selection: { if case let .choice(c)? = value { c } else { nil } }()) { choice in
                    Task { await model.setItem(camera.id, item.id, .choice(choice)) }
                }
            case .toggle:
                Toggle(item.title, isOn: Binding(get: { if case let .on(on)? = value { on } else { false } },
                                                 set: { on in Task { await model.setItem(camera.id, item.id, .on(on)) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(height: 38)
            case let .action(confirm):
                Button {
                    if confirm != nil { confirming = true } else { Task { await model.doItem(camera.id, item.id) } }
                } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .help(item.title)
                .confirmationDialog(confirm ?? "", isPresented: $confirming) {
                    Button(item.title) { Task { await model.doItem(camera.id, item.id) } }
                    Button("Cancel", role: .cancel) {}
                }
            case .slider:
                SliderItem(camera: camera, item: item)
            }
        }
    }
}

/// A slider item: its icon and name, the slider, its value. Set when let go (not at every step of a drag).
struct SliderItem: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let item: Config.Controls.Item
    /// Without its icon and name (a section heading gives them).
    var compact = false
    /// The slider's length, compact.
    var sliderWidth: CGFloat = 120
    /// Its name and value on a line, the slider under them as wide as there is room (the sidebar).
    var stacked = false
    @State private var dragging: Double?

    var body: some View {
        if case let .slider(min, max, step) = item.kind {
            let stored: Double = { if case let .number(n)? = model.itemValues[camera.id]?[item.id] { n } else { (min + max) / 2 } }()
            let shown = dragging ?? stored
            // Stepped by rounding, not by the slider's own steps (which draws tick marks under it).
            let slider = Slider(value: Binding(get: { shown }, set: { dragging = Self.stepped($0, from: min, by: step) }), in: min ... max) { editing in
                if !editing, let set = dragging {
                    Task {
                        await model.setItem(camera.id, item.id, .number(set))
                        dragging = nil
                    }
                }
            }
            .controlSize(.small)
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol).font(.callout).foregroundStyle(.secondary).frame(width: 18)
                        Text(item.title).font(.callout)
                        Spacer(minLength: 8)
                        Text("\(Int(shown.rounded()))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    slider
                }
                .help(item.title)
            } else {
            HStack(spacing: 8) {
                if !compact {
                    Image(systemName: item.symbol).font(.callout).foregroundStyle(.secondary).frame(width: 18)
                    Text(item.title).font(.callout).frame(width: 74, alignment: .leading)
                } else {
                    Image(systemName: item.symbol).font(.callout).foregroundStyle(.secondary)
                }
                slider.frame(width: compact ? sliderWidth : 110)
                // Close after the slider (room kept for three digits, so it doesn't move as the number changes).
                Text("\(Int(shown.rounded()))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
            .help(item.title)
            .frame(height: compact ? 38 : nil)
            }
        }
    }

    static func stepped(_ value: Double, from min: Double, by step: Double) -> Double {
        step > 0 ? min + ((value - min) / step).rounded() * step : value
    }
}

/// Sends moves as the pad changes, without flooding the camera: the newest move is sent once the one before
/// it has been answered, and small changes in speed aren't sent at all; a stop always is.
@MainActor
@Observable
final class PTZMover {
    private var wanted = PTZVelocity()
    private var sent = PTZVelocity()
    private var sending = false

    func set(_ velocity: PTZVelocity, camera: String, model: AppModel) {
        // Steps of a quarter: a drag's every pixel isn't a new move.
        func step(_ v: Double) -> Double { (v * 4).rounded() / 4 }
        wanted = PTZVelocity(pan: step(velocity.pan), tilt: step(velocity.tilt), zoom: step(velocity.zoom))
        guard !sending, wanted != sent else { return }
        sending = true
        Task {
            while wanted != sent {
                let next = wanted
                await model.move(camera, next)
                sent = next
            }
            sending = false
        }
    }
}

/// On a tile: talk through the camera's speaker. A click starts and stops it; while on it's lit, and swells
/// with the voice.
struct TalkButton: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    var compact = false
    /// Says above it what went wrong with the camera's controls (on a tile, where nothing else does).
    var showsErrors = true

    var body: some View {
        let talking = model.talking?.camera == camera.id
        let diameter = compact ? CameraTile.compactPillHeight : CameraTile.pillHeight
        Button { Task { await model.toggleTalk(camera.id) } } label: {
            Image(systemName: talking ? "mic.fill" : "mic")
                .font(compact ? .callout : .headline)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: talking && model.talkLevel < 0.05)
                .frame(width: diameter - 8, height: diameter - 8)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(talking ? .red : nil)
        .scaleEffect(talking ? 1 + model.talkLevel * 0.18 : 1)
        .animation(.easeOut(duration: 0.1), value: model.talkLevel)
        .help(talking ? "Stop talking through \(camera.name)" : "Talk through \(camera.name)\u{2019}s speaker")
        .overlay(alignment: .top) {
            if showsErrors, let error = model.controlError[camera.id], !talking {
                Text(error)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .fixedSize()
                    .offset(y: -30)
                    .transition(.opacity)
            }
        }
    }
}
