// A camera's zones, drawn on its picture (the latest recorded frame): watched zones, where events come from,
// and ignored ones, where nothing counts. A zone is chosen by clicking it; its corners are dragged, a corner is
// added with the + on an edge and removed from its menu, and the whole zone is dragged by its inside. What it
// takes (people, vehicles, animals, packages) and its name are beside the picture. Kept on the camera's Save.
import AppKit
import PondCore
import SwiftUI

struct ZoneEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: Config.Camera
    /// The zones as they'll be saved with the camera; set on Done.
    @Binding var zones: [Config.Zone]
    /// An ignored zone to begin with, chosen (an event's area, from its menu: Ignore This Area…).
    var ignoring: IgnoredArea? = nil
    @State private var draft: [Config.Zone] = []
    @State private var selected: String?
    @State private var picture: CGImage?
    /// The picture's shape: as last seen, until the picture comes (16:9 for a camera never seen).
    @State private var aspect: Double?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.dashed")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zones").font(.title2.bold())
                    Text(camera.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Watched Zone") { add(.watch) }
                    Button("Ignored Zone") { add(.ignore) }
                } label: {
                    Label("Add Zone", systemImage: "plus")
                }
                .fixedSize()
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 16) {
                ZoneCanvas(picture: picture, aspect: aspect ?? 16.0 / 9.0, loaded: loaded, zones: $draft, selected: $selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panel.frame(width: 260)
            }
            .padding(.horizontal, 20)

            HStack {
                Text(problem ?? "Something is in a zone when its feet (or wheels) are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    zones = draft.map { zone in
                        var z = zone
                        z.name = z.name.trimmingCharacters(in: .whitespaces)
                        return z
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
            .padding(16)
        }
        // As tall as the picture needs beside the panel (a 16:9 camera's is shorter than a 4:3 one's).
        .frame(width: Self.width, height: height)
        .onAppear {
            draft = zones
            selected = zones.first?.id
            if let ignoring { add(.ignore, points: ignoring.points, categories: ignoring.categories) }
            aspect = CameraAspect.known(camera.id)
        }
        .task {
            let base = model.config?.storage.recordingsPath ?? ""
            picture = await CameraSnapshots.latest(base: base, camera: camera.id, size: CGSize(width: 1280, height: 960))?.image
            if let picture {
                CameraAspect.remember(camera.id, picture)
                aspect = Double(picture.width) / Double(picture.height)
            }
            loaded = true
        }
    }

    static let width = 900.0
    /// The header above the picture, and the footer below it with the space between.
    static let above = 76.0, below = 68.0
    /// The panel's tallest (a watched zone's settings).
    static let panelHeight = 442.0

    var height: Double {
        let pictureWidth = Self.width - 40 - 16 - 260
        let aspect = self.aspect ?? 16.0 / 9.0
        return Self.above + max(Self.panelHeight, min(480, pictureWidth / aspect)) + Self.below
    }

    var problem: String? {
        if draft.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Give every zone a name." }
        return nil
    }

    // MARK: Beside the picture

    @ViewBuilder
    var panel: some View {
        Form {
            if draft.isEmpty {
                Section {
                    Text("No zones: everything in the picture counts. Add a watched zone to make events only from what\u{2019}s in it, or an ignored zone for a busy road or a tree in the wind.")
                        .foregroundStyle(.secondary)
                }
            }
            if let i = draft.firstIndex(where: { $0.id == selected }) {
                Section {
                    // Which zone: chosen here or by clicking it on the picture.
                    Picker("Zone", selection: Binding(get: { selected ?? "" }, set: { selected = $0 })) {
                        ForEach(draft) { zone in
                            Text(zone.name.isEmpty ? "Untitled" : zone.name).tag(zone.id)
                        }
                    }
                }
                Section {
                    TextField("Name", text: $draft[i].name)
                    LabeledContent {
                        Picker("", selection: Binding(get: { draft[i].kind ?? .watch },
                                                      set: { draft[i].kind = $0 == .watch ? nil : $0 })) {
                            Text("Watched").tag(Config.Zone.Kind.watch)
                            Text("Ignored").tag(Config.Zone.Kind.ignore)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        Text("Kind")
                    }
                    Text(draft[i].isIgnored
                         ? "Nothing that stands here counts, and nothing moving here starts detection."
                         : "Events are made only from what stands in a watched zone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !draft[i].isIgnored {
                        ForEach(Config.Zone.allCategories, id: \.self) { category in
                            Toggle(Self.title(category), isOn: Binding(
                                get: { draft[i].takes(category) },
                                set: { on in
                                    var taken = draft[i].categories ?? Config.Zone.allCategories
                                    if on { taken.append(category) } else { taken.removeAll { $0 == category } }
                                    taken = Config.Zone.allCategories.filter(taken.contains)
                                    draft[i].categories = taken == Config.Zone.allCategories ? nil : taken
                                }))
                            // One at least: a zone that takes nothing would be an ignored one.
                            .disabled(draft[i].takes(category) && (draft[i].categories?.count ?? Config.Zone.allCategories.count) == 1)
                        }
                    }
                }
                Section {
                    Button("Remove Zone", role: .destructive) {
                        let id = draft[i].id
                        draft.remove(at: i)
                        if selected == id { selected = draft.first?.id }
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -20)
        .padding(.top, -20)
    }

    static func title(_ category: String) -> String {
        switch category {
        case "person": "People"
        case "vehicle": "Vehicles and bikes"
        case "animal": "Animals"
        case "package": "Packages"
        case "item": "Left items"
        default: category.capitalized
        }
    }

    static func summary(_ zone: Config.Zone) -> String {
        guard let categories = zone.categories else { return "Everything" }
        return categories.map { title($0) }.joined(separator: ", ")
    }

    func add(_ kind: Config.Zone.Kind, points: [[Double]]? = nil, categories: [String]? = nil) {
        var n = draft.count + 1
        while draft.contains(where: { $0.id == "zone-\(n)" }) { n += 1 }
        let name = kind == .ignore ? "Ignored \(draft.filter(\.isIgnored).count + 1)" : "Zone \(draft.filter { !$0.isIgnored }.count + 1)"
        let zone = Config.Zone(id: "zone-\(n)", name: name, points: points ?? [[0.3, 0.4], [0.7, 0.4], [0.7, 0.8], [0.3, 0.8]],
                               kind: kind == .ignore ? .ignore : nil, categories: categories)
        draft.append(zone)
        selected = zone.id
    }
}

/// The picture with the zones on it, the chosen one with its corners to drag.
struct ZoneCanvas: View {
    let picture: CGImage?
    /// Its shape, known before it comes: the placeholder has it.
    let aspect: Double
    let loaded: Bool
    @Binding var zones: [Config.Zone]
    @Binding var selected: String?
    /// The chosen zone's corners as a drag of it began.
    @State private var moving: [[Double]]?

    static func color(_ zone: Config.Zone) -> Color { zone.isIgnored ? .gray : .accentColor }

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fit(aspect: aspect, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Group {
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                            .overlay {
                                Text(loaded ? "No recent picture of this camera" : "")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .onTapGesture { selected = nil }

                // Kept to the picture (its corners rounded); the chosen zone's handles may overhang it.
                ZStack(alignment: .topLeading) {
                    ForEach(zones) { zone in
                        shape(zone, in: frame)
                    }
                }
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let i = zones.firstIndex(where: { $0.id == selected }) {
                    handles(i, in: frame)
                }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        }
    }

    static func fit(aspect: Double, in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * aspect), height = width / aspect
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    static func point(_ p: [Double], in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + p[0] * frame.width, y: frame.minY + p[1] * frame.height)
    }

    static func fraction(_ p: CGPoint, in frame: CGRect) -> [Double] {
        [min(1, max(0, (p.x - frame.minX) / frame.width)), min(1, max(0, (p.y - frame.minY) / frame.height))]
    }

    static func path(_ zone: Config.Zone, in frame: CGRect) -> Path {
        Path { path in
            let points = zone.points.filter { $0.count == 2 }.map { point($0, in: frame) }
            guard let first = points.first else { return }
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
    }

    func shape(_ zone: Config.Zone, in frame: CGRect) -> some View {
        let chosen = zone.id == selected
        let path = Self.path(zone, in: frame)
        let color = Self.color(zone)
        return ZStack {
            path.fill(color.opacity(chosen ? 0.3 : 0.18))
            path.stroke(color, style: StrokeStyle(lineWidth: chosen ? 2 : 1.5, lineJoin: .round, dash: zone.isIgnored ? [6, 4] : []))
        }
        .contentShape(path)
        .onTapGesture { selected = zone.id }
        // The whole zone, dragged by its inside (the chosen one).
        .gesture(DragGesture(minimumDistance: 3).onChanged { drag in
            guard let i = zones.firstIndex(where: { $0.id == zone.id }) else { return }
            selected = zone.id
            let start = moving ?? zones[i].points
            moving = start
            // Kept inside the picture, the zone's shape unchanged.
            let xs = start.map { $0[0] }, ys = start.map { $0[1] }
            let dx = min(1 - (xs.max() ?? 1), max(-(xs.min() ?? 0), drag.translation.width / frame.width))
            let dy = min(1 - (ys.max() ?? 1), max(-(ys.min() ?? 0), drag.translation.height / frame.height))
            zones[i].points = start.map { [$0[0] + dx, $0[1] + dy] }
        }.onEnded { _ in moving = nil })
        .overlay(alignment: .topLeading) {
            if !zone.points.isEmpty {
                let label = Self.labelSize(zone.name)
                let middle = Self.labelCenter(zone.points.filter { $0.count == 2 }.map { Self.point($0, in: frame) }, size: label)
                Text(zone.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(middle)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Where a zone's name goes

    static func labelSize(_ name: String) -> CGSize {
        let text = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)])
        return CGSize(width: ceil(text.width) + 12, height: ceil(text.height) + 4)
    }

    /// The middle of the zone's area (its centroid: corners added along an edge don't move it), or, where the label
    /// wouldn't fit there inside the zone (an L, a thin wedge), the nearest place it does; the centroid if none.
    static func labelCenter(_ points: [CGPoint], size: CGSize) -> CGPoint {
        guard points.count >= 3 else { return points.first ?? .zero }
        let middle = centroid(points)
        if fits(middle, size: size, in: points) { return middle }
        let xs = points.map(\.x), ys = points.map(\.y)
        var best: (point: CGPoint, distance: Double)?
        let step = 4.0
        var y = ys.min()! + size.height / 2
        while y <= ys.max()! - size.height / 2 {
            var x = xs.min()! + size.width / 2
            while x <= xs.max()! - size.width / 2 {
                let p = CGPoint(x: x, y: y)
                let d = hypot(p.x - middle.x, p.y - middle.y)
                if d < best?.distance ?? .infinity, fits(p, size: size, in: points) { best = (p, d) }
                x += step
            }
            y += step
        }
        return best?.point ?? middle
    }

    /// The centroid of a polygon's area; the corners' average for one with none.
    static func centroid(_ p: [CGPoint]) -> CGPoint {
        var area = 0.0, cx = 0.0, cy = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        guard abs(area) > 1e-9 else {
            return CGPoint(x: p.map(\.x).reduce(0, +) / Double(p.count), y: p.map(\.y).reduce(0, +) / Double(p.count))
        }
        return CGPoint(x: cx / (3 * area), y: cy / (3 * area))
    }

    /// Whether a label this size, centred here, is wholly inside the polygon: its edge all inside, and no corner
    /// of the polygon poking into it.
    static func fits(_ center: CGPoint, size: CGSize, in polygon: [CGPoint]) -> Bool {
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if polygon.contains(where: { rect.insetBy(dx: 0.5, dy: 0.5).contains($0) }) { return false }
        let samples = 6
        for k in 0 ... samples {
            let t = Double(k) / Double(samples)
            for p in [CGPoint(x: rect.minX + t * rect.width, y: rect.minY), CGPoint(x: rect.minX + t * rect.width, y: rect.maxY),
                      CGPoint(x: rect.minX, y: rect.minY + t * rect.height), CGPoint(x: rect.maxX, y: rect.minY + t * rect.height)]
                where !inside(p, polygon) { return false }
        }
        return true
    }

    static func inside(_ point: CGPoint, _ p: [CGPoint]) -> Bool {
        var inside = false
        var j = p.count - 1
        for i in p.indices {
            if (p[i].y > point.y) != (p[j].y > point.y),
               point.x < (p[j].x - p[i].x) * (point.y - p[i].y) / (p[j].y - p[i].y) + p[i].x { inside.toggle() }
            j = i
        }
        return inside
    }

    func handles(_ i: Int, in frame: CGRect) -> some View {
        let points = zones[i].points
        let color = Self.color(zones[i])
        return ZStack(alignment: .topLeading) {
            // A corner added in the middle of each edge.
            ForEach(points.indices, id: \.self) { j in
                let a = points[j], b = points[(j + 1) % points.count]
                let middle = Self.point([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], in: frame)
                Button {
                    zones[i].points.insert([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], at: j + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .background(.background.opacity(0.85), in: Circle())
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .help("Add a corner here")
                .position(middle)
            }
            ForEach(points.indices, id: \.self) { j in
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .position(Self.point(points[j], in: frame))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("zones")).onChanged { drag in
                        guard zones[i].points.indices.contains(j) else { return }
                        zones[i].points[j] = Self.fraction(drag.location, in: frame)
                    })
                    .contextMenu {
                        Button("Remove Corner") { zones[i].points.remove(at: j) }
                            .disabled(zones[i].points.count <= 3)
                    }
            }
        }
        .coordinateSpace(name: "zones")
    }
}
