// A prototype, for laying out the dock's adjustments: controls a camera has (its abilities, as a Reolink E1
// Pro reports them) that no provider serves yet, shown so the pages can be tried. Changed here only, never
// sent to the camera. Goes once providers serve them: Reolink's IR lights (SetIrLights), status light
// (SetPowerLed), mirror and flip (SetIsp), and ONVIF's restart (SystemReboot).
import NVRCore

enum PrototypeItems {
    typealias Item = Config.Controls.Item

    static let provider = "prototype"

    static let irLights = Item(id: "irLights", title: "IR Lights", symbol: "rays", group: .light, order: 10,
                               kind: .choice([.init(value: "auto", title: "Auto", symbol: "circle.lefthalf.filled"),
                                              .init(value: "off", title: "Off", symbol: "lightbulb.slash")]),
                               provider: provider)
    static let statusLight = Item(id: "statusLight", title: "Status Light", symbol: "lightbulb.led", group: .light, order: 20,
                                  kind: .toggle, provider: provider)
    static let mirror = Item(id: "mirror", title: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             group: .device, order: 10, kind: .toggle, provider: provider)
    static let flip = Item(id: "flip", title: "Flip", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                           group: .device, order: 11, kind: .toggle, provider: provider)
    static let restart = Item(id: "restart", title: "Restart", symbol: "arrow.clockwise", group: .device, order: 90,
                              kind: .action(confirm: "Restart the camera? It goes offline for about a minute."), provider: provider)

    static let ids: Set<String> = ["irLights", "statusLight", "mirror", "flip", "restart"]

    /// As the camera had them when this was made.
    static let initial: [String: Config.Controls.Value] = [
        "irLights": .choice("auto"), "statusLight": .on(true), "mirror": .on(true), "flip": .on(true),
    ]

    /// For a Reolink camera that moves (as the one these were read from), and a restart for any.
    static func items(for camera: Config.Camera, controls: Config.Controls) -> [Item] {
        var items: [Item] = []
        if camera.device?.manufacturer.localizedCaseInsensitiveContains("reolink") == true, controls.ptz != nil {
            items += [irLights, statusLight, mirror, flip]
        }
        items.append(restart)
        return items.filter { new in !controls.items.contains { $0.id == new.id } }
    }
}
