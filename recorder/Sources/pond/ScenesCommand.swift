// `pond advanced scenes [FOLDER …] [--model ID] [--compute all|ane|gpu|cpu] [--json]`: test scenes replayed through what the
// recorder runs (WatchPipeline: motion, the model, the tracker, events) and scored: for each, what it should have
// made, what it missed, what it made that it shouldn't have, and the whole. A FOLDER is a scene (its scene.json and
// clip) or holds scenes; none given, this Pond's own (SceneLibrary, beside its database: its events said, or seen, to be
// nothing or real), which stay on its Mac. Those are judged as the app would show them: a "nothing" passes if it isn't made, or is made and
// quieted; a "real" one if it's made and not quieted; each quieted by what was learnt from everything else said, never
// from itself.
// --json prints only the scores (no footage, no pictures): what a tester's home reports (development.md: How
// detection changes are judged). Clips are best a camera's sub-stream, as detection sees it live.
#if canImport(PondMac)
import AVFoundation
import CoreMedia
import Detection
import Foundation
import PondCore
import Watch

enum ScenesCommand {
    static func run(_ args: [String], configPath: String) -> Int32 {
        var args = args
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i ... i + 1) }
            return args[i + 1]
        }
        let modelID = option("--model")
        let compute: Detector.Compute = switch option("--compute") {
        case "ane": .neuralEngine
        case "gpu": .gpu
        case "cpu": .cpu
        default: .all
        }
        let json = args.contains("--json")
        args.removeAll { $0 == "--json" }
        // None named: this Pond's own (its library, beside its database).
        let config = try? ConfigStore(path: configPath).load()
        let ownFolder = config.map { SceneLibrary(beside: $0.storage.databasePath).folder }
        let folders = scenes(in: args.isEmpty ? ownFolder.map { [$0] } ?? [] : args)
        guard !folders.isEmpty else {
            FileHandle.standardError.write(Data("✗ No scenes (a folder with scene.json and its clip)\(args.isEmpty ? " in \(ownFolder ?? "this Pond's library")" : ""): they come from what you say of events, and events you keep\n".utf8))
            return 1
        }
        guard let model = ModelStore.choose(modelID) else {
            FileHandle.standardError.write(Data("✗ No model\(modelID.map { " \($0)" } ?? ""). See: pond advanced detect models\n".utf8))
            return 1
        }
        let detector = Detector()
        do throws(Detector.Failure) { try detector.use(model, compute: compute) } catch {
            FileHandle.standardError.write(Data("✗ \(error.description)\n".utf8))
            return 1
        }
        if !json { print("\(model.manifest.name): \(folders.count) scene\(folders.count == 1 ? "" : "s")") }
        // What's been said of events, for judging an owner's own scenes as the app would (each without its own).
        let feedback: [EventFeedback] = config.flatMap {
            EventStore(path: $0.storage.databasePath, readOnly: true)?.feedback()
        } ?? []
        var total = SceneScore.zero
        var results: [[String: Any]] = []
        var own: [String: [(label: TestScene.Source.Label, result: OwnSceneResult)]] = [:]
        for folder in folders {
            guard let scene = try? TestScene.read(folder: folder) else {
                FileHandle.standardError.write(Data("✗ \(folder): no readable scene.json\n".utf8))
                return 1
            }
            let clip = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(scene.clip))
            guard let made = replay(scene, clip: clip, detector: detector) else {
                FileHandle.standardError.write(Data("✗ \(scene.name): its clip (\(scene.clip)) couldn't be read\n".utf8))
                return 1
            }
            // An owner's own: judged as the app would show it.
            if let source = scene.source, let result = OwnSceneResult.judge(scene, made: made, feedback: feedback) {
                own[source.camera, default: []].append((source.label, result))
                if !json {
                    print("\(result == .passed ? "✓" : "✗") \(scene.name): \(words(result))")
                }
                continue
            }
            let score = SceneScore.score(expected: scene.expect, made: made)
            total = total + score
            results.append(["scene": scene.name, "hits": score.hits, "misses": score.misses, "false": score.falseEvents, "splits": score.splits])
            if !json {
                let mark = score.misses == 0 && score.falseEvents == 0 ? "✓" : "✗"
                print("\(mark) \(scene.name): \(words(score, expected: scene.expect.count))")
                for m in made { print(String(format: "    made %@ %.1f–%.1f s", m.kind, m.from, m.to)) }
            }
        }
        // An owner's own, by camera: of what they said wasn't anything, how many this build keeps out of sight; of what
        // was real, how many it shows; and whether there are enough of each to go by.
        var ownReport: [[String: Any]] = []
        var ownFailed = false
        for (camera, results) in own.sorted(by: { $0.key < $1.key }) {
            let nothing = results.filter { $0.label == .nothing }, real = results.filter { $0.label == .real }
            let kept = nothing.count { $0.result == .passed }, shown = real.count { $0.result == .passed }
            let missed = real.count { $0.result == .missed }, hidden = real.count { $0.result == .hidden }
            ownFailed = ownFailed || hidden > 0 || missed > 0 || kept < nothing.count
            ownReport.append(["camera": camera, "nothing": nothing.count, "nothingKeptOut": kept, "real": real.count,
                              "realShown": shown, "realMissed": missed, "realHidden": hidden,
                              "enough": nothing.count >= SceneLibrary.enough && real.count >= SceneLibrary.enough])
            if !json {
                var line = "\(camera): of \(nothing.count) dismissed, \(kept) kept out of sight; of \(real.count) real, \(shown) shown"
                if missed > 0 { line += ", \(missed) missed" }
                if hidden > 0 { line += ", \(hidden) hidden" }
                if nothing.count < SceneLibrary.enough || real.count < SceneLibrary.enough {
                    line += " (too few to rely on yet: \(SceneLibrary.enough) of each, at least)"
                }
                print(line)
            }
        }
        if json {
            var report: [String: Any] = ["model": model.manifest.name, "scenes": results,
                                         "total": ["hits": total.hits, "misses": total.misses, "false": total.falseEvents, "splits": total.splits]]
            if !ownReport.isEmpty { report["own"] = ownReport }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else if !results.isEmpty {
            print("All: \(total.hits) found, \(total.misses) missed, \(total.falseEvents) made that shouldn't have been, \(total.splits) split")
        }
        return total.misses == 0 && total.falseEvents == 0 && !ownFailed ? 0 : 2
    }

    static func words(_ result: OwnSceneResult) -> String {
        switch result {
        case .passed: "as you said"
        case .missed: "real, and not made: missed"
        case .hidden: "real, made, and quieted: hidden"
        case .shown: "said not to be anything, and shown again"
        }
    }

    static func words(_ s: SceneScore, expected: Int) -> String {
        if expected == 0, s.falseEvents == 0 { return "nothing, as it should" }
        var parts = ["\(s.hits) of \(expected) found"]
        if s.misses > 0 { parts.append("\(s.misses) missed") }
        if s.falseEvents > 0 { parts.append("\(s.falseEvents) made that shouldn't have been") }
        if s.splits > 0 { parts.append("\(s.splits) split") }
        return parts.joined(separator: ", ")
    }

    /// The scene folders: each one given that has a scene.json, else the ones inside it that do.
    static func scenes(in paths: [String]) -> [String] {
        let fm = FileManager.default
        return paths.flatMap { path -> [String] in
            let expanded = NSString(string: path).expandingTildeInPath
            if fm.fileExists(atPath: (expanded as NSString).appendingPathComponent("scene.json")) { return [expanded] }
            return ((try? fm.contentsOfDirectory(atPath: expanded)) ?? []).sorted()
                .map { (expanded as NSString).appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent("scene.json")) }
        }
    }

    /// The clip's pictures, one at a time as they're decoded (a night's clip isn't held in memory), through the
    /// pipeline; nil if it can't be read.
    static func replay(_ scene: TestScene, clip: URL, detector: Detector) -> [MadeEvent]? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var made: [MadeEvent]?
        Task {
            made = try? await stream(scene, clip: clip, detector: detector)
            semaphore.signal()
        }
        semaphore.wait()
        return made
    }

    static func stream(_ scene: TestScene, clip: URL, detector: Detector) async throws -> [MadeEvent] {
        let asset = AVURLAsset(url: clip)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var replay = SceneReplay(scene: scene)
        while let sample = try await provider.next() {
            let time = sample.presentationTimeStamp.seconds
            nonisolated(unsafe) var buffer: CVPixelBuffer?
            sample.withUnsafeSampleBuffer { buffer = CMSampleBufferGetImageBuffer($0) }
            guard let picture = buffer else { continue }
            let gate = replay.pipeline.gate
            replay.picture(at: time, cells: {
                CVPixelBufferLockBaseAddress(picture, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
                return CVPixelBufferGetBaseAddress(picture).map {
                    MotionGate.cells(bgra: $0.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(picture),
                                     height: CVPixelBufferGetHeight(picture), stride: CVPixelBufferGetBytesPerRow(picture),
                                     columns: gate.columns, rows: gate.rows)
                } ?? []
            }, detect: { mask in
                // As the service, with no main stream to look closer at: the model on the whole picture, and closer
                // up at what moves in it.
                CloserLook.look({ try? detector.detect($0) }, whole: picture, closer: nil, mask: mask)
            })
        }
        return replay.finish()
    }
}
#endif
