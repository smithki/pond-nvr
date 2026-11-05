// The live view's spacing across, in one place. The view is laid out with these (the rail's padding, the dock's
// inset, the adjustments' sidebar), and the room left for the dock is worked out from the same values (which
// arrangement fits, whether the rail or the sidebar fits beside it), so the two can't drift apart: change one
// here and both follow.
import CoreGraphics
import os
import SwiftUI

@MainActor
enum LiveLayout {
    /// The dock's inset from the stage column's sides.
    static let dockInset: CGFloat = 12
    /// The stage column's width less the dock's room: the dock's insets.
    static var stageMargins: CGFloat { 2 * dockInset }

    /// The cameras' rail's padding (round its list), on its left and its right.
    static let railLeading: CGFloat = 12
    static let railTrailing: CGFloat = 6
    /// What the rail takes across at `width` (its own width, as kept and dragged).
    static func railRoom(_ width: Double) -> CGFloat { CGFloat(width.clamped(to: CameraRail.widths)) + railLeading + railTrailing }

    /// The adjustments' sidebar (beside the stage): its width, and its inset from the window's edge.
    static let sidebarWidth: CGFloat = 280
    static let sidebarInset: CGFloat = 12
    static var sidebarRoom: CGFloat { sidebarWidth + sidebarInset }

    /// The narrowest dock of a camera with every everyday control (day and night, a picture, privacy;
    /// positions, talking, volume, home), as measured.
    static let narrowestDock: CGFloat = 604
    /// The window's narrowest: that dock with the stage's margins (the rail out of the way, the adjustments a
    /// frame of the dock), so the dock never has to shrink; narrow enough for half of any Mac's screen.
    static let minimumWindowWidth: CGFloat = 640

    // MARK: Checks

    static let log = Logger(subsystem: "camera.pond", category: "layout")
    private static var said: Set<String> = []

    /// Says so (once each) when the room worked out from these values isn't what the view laid out: something
    /// across the live view was changed without them (a padding, a new panel), and the dock would choose
    /// wrongly.
    static func check(room expected: CGFloat, measured: CGFloat) {
        guard abs(expected - measured) > 2 else { return }
        let key = "room \(Int(expected)) \(Int(measured))"
        guard said.insert(key).inserted else { return }
        log.fault("Live layout: the dock's room worked out as \(Int(expected)) pt, laid out as \(Int(measured)) pt. Is something across the live view spaced without LiveLayout?")
    }

    /// Says so (once each) when a camera's narrowest dock is wider than `narrowestDock`: an everyday control was
    /// added, and the window's narrowest would make the dock shrink. Measure it again and raise both.
    static func check(narrowest: CGFloat, camera: String) {
        guard narrowest > narrowestDock + 1, said.insert("narrowest \(camera) \(Int(narrowest))").inserted else { return }
        log.fault("Live layout: \(camera)'s narrowest dock is \(Int(narrowest)) pt, wider than narrowestDock (\(Int(narrowestDock)) pt). Raise narrowestDock and minimumWindowWidth.")
    }

    /// A side panel's corners (the rail's, the adjustments' sidebar's): 20 pt, floating on the stage; the one by
    /// the window's corner follows the window's curve instead, its radius less the panel's inset (as an iOS sheet's
    /// bottom corners do the screen's), never under 8 pt.
    static let panelRadius: CGFloat = 20

    static func panel(nearWindowCorner corner: Edge.Corner) -> ConcentricRectangle {
        let floating = Edge.Corner.Style.fixed(panelRadius)
        let window = Edge.Corner.Style.concentric(minimum: .fixed(8))
        return ConcentricRectangle(topLeadingCorner: floating, topTrailingCorner: floating,
                                   bottomLeadingCorner: corner == .bottomLeading ? window : floating,
                                   bottomTrailingCorner: corner == .bottomTrailing ? window : floating)
    }
}

extension ConcentricRectangle {
    /// A panel's corners: `radius`, floating; down by the window's bottom edge, the bottom two follow the window's
    /// curve instead, its radius less the panel's inset (as an iOS sheet's bottom corners do the screen's), never
    /// under 8 pt.
    static func panel(radius: CGFloat, byWindowBottom: Bool) -> ConcentricRectangle {
        let floating = Edge.Corner.Style.fixed(radius)
        let window = byWindowBottom ? Edge.Corner.Style.concentric(minimum: .fixed(8)) : floating
        return ConcentricRectangle(topLeadingCorner: floating, topTrailingCorner: floating,
                                   bottomLeadingCorner: window, bottomTrailingCorner: window)
    }
}
