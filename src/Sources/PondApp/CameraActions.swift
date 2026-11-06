// A camera's settings and zones, from where one sees it: its tile in Live (on the stage and in the rail) and its
// events, by their menus, not only from Settings › Cameras. From an event, Ignore This Area… opens the zone editor
// with the event's box drawn as an ignored zone (for the event's kind: a parked car's spot ignored needn't hide
// someone walking past it), to adjust and keep.
import AppKit
import Detection
import PondCore
import SwiftUI

/// The zone editor, asked for from the main window: a camera's, perhaps with an ignored zone drawn already.
struct ZoneEditing: Identifiable, Equatable {
    var camera: String
    /// An ignored zone to begin with (its corners, and the kinds it ignores; nil, every kind).
    var ignoring: IgnoredArea?
    var id: String { camera }
}

struct IgnoredArea: Equatable {
    var points: [[Double]]
    var categories: [String]?

    /// Room round the event's box, a share of its size on each side (what moved there moves a little).
    static let margin = 0.15

    /// Round an event's box (a share of the picture, from its top left): a little larger, inside the picture; for its
    /// kind alone where it has one a zone knows.
    init?(_ event: TimelineEvent) {
        guard let box = event.box, box.width > 0, box.height > 0 else { return nil }
        let dx = box.width * Self.margin, dy = box.height * Self.margin
        let left = max(0, box.x - dx), top = max(0, box.y - dy)
        let right = min(1, box.x + box.width + dx), bottom = min(1, box.y + box.height + dy)
        points = [[left, top], [right, top], [right, bottom], [left, bottom]]
        categories = Self.category(event.kind).map { [$0] }
    }

    init(points: [[Double]], categories: [String]?) {
        self.points = points
        self.categories = categories
    }

    /// The kind as a zone takes it (a bike's one of the vehicles); nil for what a zone doesn't sort (a ring, motion).
    static func category(_ kind: TimelineEvent.Kind) -> String? {
        switch kind {
        case .person: "person"
        case .vehicle, .bike: "vehicle"
        case .animal: "animal"
        case .package: "package"
        case .item: "item"
        case .ring, .motion, .privacy: nil
        }
    }
}

extension AppModel {
    /// This Mac's camera by its id (another Pond's isn't set up here).
    func ownCamera(_ id: String) -> Config.Camera? {
        AppModel.pond(of: id) == nil ? config?.cameras.first { $0.id == id } : nil
    }

    /// Whether a camera's zones can be edited from here: this Mac's, with detection on (zones are what it watches).
    func canEditZones(_ id: String) -> Bool { ownCamera(id)?.watches == true }

    /// The zone editor, over the main window: the camera's zones, perhaps with an event's box to ignore drawn in.
    func editZones(_ camera: String, ignoring event: TimelineEvent? = nil) {
        guard canEditZones(camera) else { return }
        zoneEditing = ZoneEditing(camera: camera, ignoring: event.flatMap(IgnoredArea.init))
    }

    /// A camera alone on Live's stage, in the main window brought forward (its Pond shown, if it wasn't).
    func showInLive(_ camera: String) {
        if !shownPonds.includes(AppModel.pond(of: camera)) { shownPonds = .all }
        mode = .live
        soloRequest = camera
        AppModel.openWindow?("main")
    }

    /// The camera's settings, on its page in the camera window.
    func showCameraSettings(_ camera: String) { showCamera(camera, tab: .settings) }

    /// A camera's zones, kept as the editor's Done gives them.
    func saveZones(_ zones: [Config.Zone], for camera: String) {
        _ = update { config in
            if let i = config.cameras.firstIndex(where: { $0.id == camera }) { config.cameras[i].zones = zones }
        }
    }
}

/// The zone editor as the main window's sheet (ContentView).
struct ZoneEditingSheet: View {
    @Environment(AppModel.self) private var model
    let editing: ZoneEditing

    var body: some View {
        if let camera = model.ownCamera(editing.camera) {
            ZoneEditorSheet(camera: camera,
                            zones: Binding(get: { camera.zones }, set: { model.saveZones($0, for: camera.id) }),
                            ignoring: editing.ignoring)
        }
    }
}
