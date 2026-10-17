// Pictures of a camera's positions (its PTZ presets), taken from its live view: when a position is kept, and
// each time the camera is sent to one (once it has had time to get there, if it isn't moved by hand
// meanwhile), so each shows what was there the last time it was seen. Kept as small JPEGs beside the
// settings, in Positions/<camera>/<position>.jpg.
import AppKit
import AVFoundation
import CoreImage
import Devices
import SwiftUI

extension AppModel {
    /// Watching for a camera to arrive at a position: how soon to start, how often to look, how long at most.
    static let arrivalStart: Duration = .milliseconds(600)
    static let arrivalStep: Duration = .milliseconds(250)
    static let arrivalLimit: Duration = .seconds(6)

    var presetPicturesFolder: URL {
        URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("Positions", isDirectory: true)
    }

    func presetPictureFile(_ camera: String, _ preset: String) -> URL {
        presetPicturesFolder.appendingPathComponent(camera, isDirectory: true)
            .appendingPathComponent(preset.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    static func presetKey(_ camera: String, _ preset: String) -> String { "\(camera)/\(preset)" }

    /// The pictures kept for these positions, read in.
    func loadPresetPictures(_ camera: String, _ presets: [PTZPreset]) {
        for preset in presets where presetPictures[Self.presetKey(camera, preset.id)] == nil {
            if let image = NSImage(contentsOf: presetPictureFile(camera, preset.id)) {
                presetPictures[Self.presetKey(camera, preset.id)] = image
            }
        }
    }

    /// What the camera's tile shows now, kept as this position's picture.
    func takePresetPicture(_ camera: String, _ preset: String) {
        guard let image = liveFeeds[camera]?.picture(width: 320) else { return }
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        presetPictures[Self.presetKey(camera, preset)] = picture
        let file = presetPictureFile(camera, preset)
        Task.detached {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Takes the picture as soon as the camera has arrived (its picture has stopped changing: two looks in a
    /// row alike), unless it's been moved by hand since; at the latest, after a few seconds.
    func takePresetPictureOnArrival(_ camera: String, _ preset: String) {
        atPreset[camera] = preset
        Task {
            try? await Task.sleep(for: Self.arrivalStart)
            let started = ContinuousClock.now
            var last: [UInt8]?
            var still = 0
            // Stillness counts once it has moved, or after a moment if it never does (it was there already):
            // before it starts moving, it's still too.
            var moved = false
            while atPreset[camera] == preset, ContinuousClock.now - started < Self.arrivalLimit {
                let now = liveFeeds[camera]?.picture(width: 48).map(Self.greys)
                if let now, let last, Self.difference(now, last) < 6 {
                    still += 1
                    if still >= 2, moved || ContinuousClock.now - started > .milliseconds(1500) { break }
                } else {
                    if last != nil, now != nil { moved = true }
                    still = 0
                }
                last = now
                try? await Task.sleep(for: Self.arrivalStep)
            }
            if atPreset[camera] == preset { takePresetPicture(camera, preset) }
        }
    }

    /// A small picture's brightness, pixel by pixel.
    static func greys(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// How different two such pictures are: the average change in brightness (0–255).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
    }

    static func orderKey(_ camera: String) -> String { "positionOrder.\(camera)" }

    /// A camera's positions as last asked, kept between launches.
    static func keptPresets(_ camera: String) -> [PTZPreset] {
        guard let data = UserDefaults.standard.data(forKey: "positions.\(camera)") else { return [] }
        return (try? JSONDecoder().decode([PTZPreset].self, from: data)) ?? []
    }

    static func keepPresets(_ camera: String, _ list: [PTZPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "positions.\(camera)")
    }

    /// Positions not seen before join the end of the kept order, so a new one comes after the others (a
    /// camera numbers a new one by its first free place, which could put it first, pushing another into More).
    func rememberOrder(_ camera: String, _ list: [PTZPreset]) {
        let ids = list.map(\.id)
        var order = (UserDefaults.standard.stringArray(forKey: Self.orderKey(camera)) ?? []).filter(ids.contains)
        let unseen = ids.filter { !order.contains($0) }
        guard !unseen.isEmpty || order.count != (UserDefaults.standard.stringArray(forKey: Self.orderKey(camera)) ?? []).count
        else { return }
        order += unseen
        UserDefaults.standard.set(order, forKey: Self.orderKey(camera))
    }

    /// A removed position leaves the kept order: a camera reuses its place (and its id) for the next one kept,
    /// which would otherwise take the removed one's place instead of coming last.
    func forgetOrder(_ camera: String, _ preset: String) {
        let order = UserDefaults.standard.stringArray(forKey: Self.orderKey(camera)) ?? []
        UserDefaults.standard.set(order.filter { $0 != preset }, forKey: Self.orderKey(camera))
    }

    /// A camera's positions in the order they're shown: the order they were first seen and then dragged into
    /// (kept here: cameras keep their own).
    func orderedPresets(_ camera: String) -> [PTZPreset] {
        // As last known (kept between launches) until the camera answers, so the dock opens with them in place.
        let list = presets[camera] ?? Self.keptPresets(camera)
        let order = UserDefaults.standard.stringArray(forKey: Self.orderKey(camera)) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { a, b in
            (rank[a.element.id] ?? order.count + a.offset, a.offset) < (rank[b.element.id] ?? order.count + b.offset, b.offset)
        }.map(\.element)
    }

    /// Moves a position to where another is (before it, or after it if it came from before).
    func movePreset(_ camera: String, _ moved: String, to target: String) {
        guard moved != target else { return }
        var ids = orderedPresets(camera).map(\.id)
        guard let from = ids.firstIndex(of: moved), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(moved, at: to)
        UserDefaults.standard.set(ids, forKey: Self.orderKey(camera))
        // Shown again in the new order.
        withAnimation(.snappy(duration: 0.25)) { presets[camera] = presets[camera] }
    }

    func forgetPresetPicture(_ camera: String, _ preset: String) {
        presetPictures[Self.presetKey(camera, preset)] = nil
        try? FileManager.default.removeItem(at: presetPictureFile(camera, preset))
    }
}

extension LiveStream {
    /// The picture showing now, at most `width` pixels wide.
    func picture(width: Int) -> CGImage? {
        guard let buffer = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, CGFloat(width) / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
