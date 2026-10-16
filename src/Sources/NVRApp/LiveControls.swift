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

/// A choice among a few, by icon, on glass: the chosen one lit.
struct IconChoice<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        let systemImage: String
    }

    let options: [Option]
    let selection: Value?
    let choose: (Value) -> Void
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button { choose(option.value) } label: {
                        VStack(spacing: 3) {
                            Image(systemName: option.systemImage).font(.system(size: 15, weight: .semibold))
                            Text(option.title).font(.caption2.weight(.medium))
                        }
                        .frame(width: 52, height: 46)
                        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(chosen ? .regular.tint(.accentColor.opacity(0.75)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 12))
                    .glassEffectID(option.title, in: glass)
                    .help(option.title)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: selection)
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
    @State private var mover = PTZMover()
    /// The camera shown, which follows `camera` a moment later, in an update of its own (the stage switches
    /// cameras without animation, which would otherwise swap the controls at once): so they crossfade.
    @State private var shown: (camera: Config.Camera, controls: Config.Controls)?

    /// Each side's width in the full layout, so the pad stays in the middle whatever is beside it.
    nonisolated static let sideWidth: CGFloat = 300
    nonisolated static let spacing: CGFloat = 36
    nonisolated static let height: CGFloat = 164

    /// Which arrangement fits the dock's width: chosen by width (rather than by trying each), so a change
    /// between them can crossfade.
    enum Arrangement: Equatable {
        case full, beside, narrow

        static func fitting(_ width: CGFloat) -> Arrangement {
            width >= 2 * LiveControlsDock.sideWidth + 124 + 2 * LiveControlsDock.spacing + 48 ? .full
                : width >= 124 + 280 + 0.75 * LiveControlsDock.spacing + 48 ? .beside : .narrow
        }
    }

    @State private var arrangement = Arrangement.full

    var current: (camera: Config.Camera, controls: Config.Controls) { shown ?? (camera, controls) }

    var body: some View {
        // The room it's given, measured by something that takes only that (the dock is drawn over it, so its
        // own width never pushes the window's layout wider), choosing the arrangement that fits.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .onGeometryChange(for: Arrangement.self) { Arrangement.fitting($0.size.width) } action: { fitting in
                withAnimation(.easeInOut(duration: 0.25)) { arrangement = fitting }
            }
            .overlay { dock }
            .onAppear { shown = (camera, controls) }
            // The same camera's controls changed (identified again): kept up, without a fade.
            .onChange(of: controls) { if shown?.camera.id == camera.id { shown = (camera, controls) } }
            .onChange(of: camera.id) {
                mover.set(PTZVelocity(), camera: current.camera.id, model: model)
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.3)) { shown = (camera, controls) }
                }
            }
    }

    var dock: some View {
        let (camera, controls) = current
        return ZStack {
            DockContents(camera: camera, controls: controls, arrangement: arrangement, mover: mover)
                .id(camera.id)
                .transition(.opacity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(height: Self.height)
        // Inside the glass: what fades out as something else comes in stays within the panel's edges.
        .clipShape(.rect(cornerRadius: 26))
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .overlay(alignment: .bottom) {
            if let error = model.controlError[camera.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .offset(y: 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.controlError[camera.id])
        .task(id: camera.id) {
            if (controls.ptz?.presets ?? 0) > 0 { await model.loadPresets(camera.id) }
            if controls.nightMode != nil { await model.loadNightMode(camera.id) }
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
        .onDisappear { mover.set(PTZVelocity(), camera: camera.id, model: model) }
    }
}

/// One camera's controls in the dock, in the arrangement that fits.
struct DockContents: View {
    @Environment(AppModel.self) private var model
    let camera: Config.Camera
    let controls: Config.Controls
    let arrangement: LiveControlsDock.Arrangement
    let mover: PTZMover
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ZStack {
            switch arrangement {
            case .full:
                // Positions | pad | day & night.
                HStack(alignment: .center, spacing: LiveControlsDock.spacing) {
                    positions(width: LiveControlsDock.sideWidth).frame(width: LiveControlsDock.sideWidth, alignment: .trailing)
                    pad
                    VStack(alignment: .leading, spacing: 14) {
                        nightMode
                        zoom
                    }
                    .frame(width: LiveControlsDock.sideWidth, alignment: .leading)
                }
                .transition(.opacity)
            case .beside:
                // The pad, then the rest beside it.
                HStack(alignment: .center, spacing: LiveControlsDock.spacing * 0.75) {
                    pad
                    VStack(alignment: .leading, spacing: 12) {
                        positions(width: 260)
                        HStack(spacing: 20) {
                            nightMode
                            zoom
                        }
                    }
                    .frame(width: 280, alignment: .leading)
                }
                .transition(.opacity)
            case .narrow:
                // The pad, day and night, and the positions as a menu.
                HStack(alignment: .center, spacing: 20) {
                    pad
                    VStack(alignment: .leading, spacing: 12) {
                        positionsMenu
                        nightMode
                    }
                }
                .transition(.opacity)
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
                ChipStrip(items: model.presets[camera.id] ?? [], title: \.name,
                          tap: { preset in Task { await model.goTo(camera.id, preset: preset.id) } },
                          menu: { preset in presetMenu(preset) },
                          add: { newName = ""; naming = true }, addHelp: "Keep where it points now as a position",
                          empty: "No positions yet")
                    .frame(maxWidth: width, alignment: .leading)
                    .popover(isPresented: $naming, arrowEdge: .top) { namer }
            }
        }
    }

    /// The positions in a menu, for a narrow window.
    @ViewBuilder var positionsMenu: some View {
        if let ptz = controls.ptz, ptz.presets > 0 {
            Menu {
                ForEach(model.presets[camera.id] ?? []) { preset in
                    Button(preset.name) { Task { await model.goTo(camera.id, preset: preset.id) } }
                }
                Divider()
                Button("Keep Where It Points Now\u{2026}") { newName = ""; naming = true }
            } label: {
                Label("Positions", systemImage: "scope")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .popover(isPresented: $naming, arrowEdge: .top) { namer }
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

    @ViewBuilder var nightMode: some View {
        if let night = controls.nightMode {
            ControlSection(title: "Day & Night") {
                IconChoice(options: NightMode.allCases.filter { night.choices.contains($0.rawValue) }.map(Self.option),
                           selection: model.nightModes[camera.id]) { mode in
                    Task { await model.setNightMode(camera.id, mode) }
                }
            }
        }
    }

    func save() {
        guard !newName.isEmpty else { return }
        naming = false
        let name = newName
        Task { await model.savePreset(camera.id, name: name) }
    }

    static func option(_ mode: NightMode) -> IconChoice<NightMode>.Option {
        switch mode {
        case .auto: .init(value: .auto, title: "Auto", systemImage: "circle.lefthalf.filled")
        case .day: .init(value: .day, title: "Day", systemImage: "sun.max.fill")
        case .night: .init(value: .night, title: "Night", systemImage: "moon.stars.fill")
        }
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
            if let error = model.controlError[camera.id], !talking {
                Text(error)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .offset(y: -30)
                    .transition(.opacity)
            }
        }
    }
}
