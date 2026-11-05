// Pictures from the live view: what a camera shows now, at the resolution it's playing (its main stream when
// watched on its own), saved as a JPEG to Pictures/Pond, named for the camera and the time.
import AppKit
import CoreImage
import PondCore

extension AppModel {
    static var picturesFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pond", isDirectory: true)
    }

    /// Saves what the camera's tile shows now; its tile flashes, and the dock says where it went.
    func takePicture(_ camera: Config.Camera) {
        guard let image = liveFeeds[camera.id]?.picture(width: .max) else {
            showControlError(camera.id, "There\u{2019}s no picture to take yet")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(camera.name) \(formatter.string(from: Date())).jpg".replacingOccurrences(of: "/", with: "-")
        let file = Self.picturesFolder.appendingPathComponent(name)
        // The shutter, as macOS's screenshots sound.
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
                byReference: true)?.play()
        flash = camera.id
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if flash == camera.id { flash = nil }
        }
        Task.detached {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.92]),
                  (try? data.write(to: file, options: .atomic)) != nil else {
                await MainActor.run { self.showControlError(camera.id, "The picture couldn\u{2019}t be saved") }
                return
            }
            await MainActor.run {
                self.savedPicture = (camera.id, file)
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if self.savedPicture?.file == file { self.savedPicture = nil }
                }
            }
        }
    }
}
