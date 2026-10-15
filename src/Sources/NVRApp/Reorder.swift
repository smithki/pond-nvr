// Drag to reorder cameras, with the others moving out of the way while the drag is under way (rather than
// only when it is dropped). Used by the live view's rail and stage, and the cameras in Settings; each move updates the cameras' saved
// order, which is their priority everywhere.
import AppKit
import SwiftUI

/// The camera being dragged, shared by everything that can be dropped onto.
@MainActor
@Observable
final class ReorderDrag {
    /// Where a drag started.
    enum Source { case rail, stage, settings }

    var camera: String?
    var source: Source?
    /// The camera the pointer is over, and when the last move was made.
    var over: String?
    var lastMove = Date.distantPast
    /// Where the pointer was (on screen) at the last move.
    var lastMovePointer: CGPoint?
    private var watch: Task<Void, Never>?

    /// Moves wait this long after the last: the tiles are still sliding, and the pointer crossing a moving
    /// tile (or the gap between two) would otherwise send the camera back and forth.
    static let settle: TimeInterval = 0.35

    /// Moves the dragged camera onto the one under the pointer, once the last move has settled and the
    /// pointer has moved since: tiles sliding under a still pointer never move anything.
    func moveIfSettled(_ move: (String, String) -> Void) {
        guard let camera, let over, over != camera, Date().timeIntervalSince(lastMove) > Self.settle else { return }
        let pointer = NSEvent.mouseLocation
        if let last = lastMovePointer, hypot(pointer.x - last.x, pointer.y - last.y) < 1 { return }
        lastMove = Date()
        lastMovePointer = pointer
        move(camera, over)
    }

    /// Starts a drag; it ends when the mouse button comes up, wherever it is dropped.
    func begin(_ id: String, from source: Source) -> NSItemProvider {
        self.source = source
        camera = id
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(150))
            }
            camera = nil
            self.source = nil
            over = nil
            lastMovePointer = nil
        }
        return NSItemProvider(object: id as NSString)
    }
}

/// Moves the dragged camera to the place of the one it is over: at once when it arrives, or once the last
/// move has settled if it arrives while tiles are still sliding.
struct ReorderDropDelegate: DropDelegate {
    let target: String
    let drag: ReorderDrag
    var enabled = true
    let move: (_ camera: String, _ onto: String) -> Void

    func validateDrop(info: DropInfo) -> Bool { enabled && drag.camera != nil }

    func dropEntered(info: DropInfo) {
        guard enabled else { return }
        drag.over = target
        drag.moveIfSettled(move)
    }

    func dropExited(info: DropInfo) {
        if drag.over == target { drag.over = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Called as the pointer moves: catches up with a camera entered while things were settling.
        if enabled { drag.moveIfSettled(move) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        drag.camera = nil
        drag.source = nil
        drag.over = nil
        return true
    }
}

extension View {
    /// Makes a camera draggable to reorder, and a place to drop others onto. Always applied (disabled rather
    /// than left off), so turning it on or off never makes the view a different one. Without `label`, nothing
    /// follows the pointer: the dimmed camera, and the others moving out of its way, show the drag.
    func reorderable(_ id: String, name: String, drag: ReorderDrag, from source: ReorderDrag.Source, enabled: Bool = true,
                     label: Bool = true, move: @escaping (String, String) -> Void) -> some View {
        self
            .opacity(drag.camera == id ? 0.45 : 1)
            .animation(.easeOut(duration: 0.15), value: drag.camera == id)
            // A preview of its own: by default the system draws the view itself into an image to drag, and
            // drawing its glass (the tile's badges) that way crashed the app.
            .onDrag { enabled ? drag.begin(id, from: source) : NSItemProvider() } preview: {
                if label { DragPreview(name: name) } else { Color.clear.frame(width: 1, height: 1) }
            }
            .onDrop(of: [.text], delegate: ReorderDropDelegate(target: id, drag: drag, enabled: enabled, move: move))
    }
}

/// What follows the pointer while a camera is dragged: its name on a plain card (no glass or blending, which
/// the drag image can't draw).
struct DragPreview: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "video.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
