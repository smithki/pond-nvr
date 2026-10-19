import Foundation
import Testing
@testable import Detection

@Suite struct DecoderTests {
    static let manifest = DetectionModelManifest(name: "test", license: "test", inputSize: [640, 640], output: .endToEnd)
    static let labels = ["person", "bicycle", "car", "dog", "package"]

    @Test func aLetterboxedBoxComesBackAsAShareOfThePicture() {
        // A 1920×1080 picture in 640×640: scaled by 1/3, 140 px of padding above and below.
        let letterbox = Letterbox(image: (1920, 1080), input: (640, 640))
        #expect(abs(letterbox.scale - 1.0 / 3) < 1e-9)
        #expect(abs(letterbox.padY - 140) < 1e-9)
        let box = letterbox.box(left: 0, top: 140, right: 320, bottom: 320)   // the top-left quarter
        #expect(abs(box.x) < 1e-9 && abs(box.y) < 1e-9)
        #expect(abs(box.width - 0.5) < 1e-9 && abs(box.height - 0.5) < 1e-9)
    }

    @Test func endToEndRowsAreDetectionsAboveTheMinimum() {
        let letterbox = Letterbox(image: (640, 640), input: (640, 640))
        let values: [Float] = [
            64, 64, 128, 192, 0.9, 0,    // a person
            320, 320, 400, 400, 0.6, 2,  // a car
            0, 0, 10, 10, 0.1, 3,        // a dog, too unsure
        ]
        let found = DetectionDecoder.endToEnd(values, count: 3, letterbox: letterbox, labels: Self.labels,
                                              manifest: Self.manifest, minimum: 0.35)
        #expect(found.map(\.label) == ["person", "car"])
        #expect(found.map(\.category) == [.person, .vehicle])
        #expect(abs(found[0].box.x - 0.1) < 1e-6 && abs(found[0].box.height - 0.2) < 1e-6)
    }

    @Test func rawCandidatesOfAClassAreSuppressedWhereTheyOverlap() {
        // Three anchors, two classes (channel first): two near-identical people, one dog elsewhere.
        let anchors = 3
        let cx: [Float] = [100, 102, 500], cy: [Float] = [100, 101, 500], w: [Float] = [50, 50, 40], h: [Float] = [80, 80, 40]
        let person: [Float] = [0.9, 0.8, 0.0], dog: [Float] = [0.0, 0.1, 0.7]
        let values = cx + cy + w + h + person + dog
        let found = DetectionDecoder.yoloRaw(values, classes: 2, anchors: anchors, letterbox: Letterbox(image: (640, 640), input: (640, 640)),
                                             labels: ["person", "dog"], manifest: Self.manifest, minimum: 0.35)
        #expect(found.map(\.label) == ["person", "dog"])
        #expect(found[0].confidence == Double(Float(0.9)))
    }

    @Test func detrQueriesTakeTheirBestClassAsASigmoid() {
        let boxes: [Float] = [0.5, 0.5, 0.2, 0.4, 0.1, 0.1, 0.05, 0.05]
        let logits: [Float] = [3, -3, -5, -5]   // query 0: class 0 (sure); query 1: nothing
        let found = DetectionDecoder.detr(boxes: boxes, logits: logits, queries: 2, classes: 2,
                                          letterbox: Letterbox(image: (640, 640), input: (640, 640)), input: (640, 640),
                                          labels: ["person", "car"], manifest: Self.manifest, minimum: 0.35)
        #expect(found.count == 1 && found[0].label == "person")
        #expect(abs(found[0].box.width - 0.2) < 1e-6)
    }

    @Test func ultralyticsNamesAreReadFromItsMetadata() {
        #expect(Detector.parseNames("{0: 'person', 1: 'bicycle', 2: \"car\"}") == ["person", "bicycle", "car"])
    }

    @Test func labelsArePutInPondsTerms() {
        #expect(DetectedCategory.forLabel("truck") == .vehicle)
        #expect(DetectedCategory.forLabel("Cat") == .animal)
        #expect(DetectedCategory.forLabel("toaster") == .other)
        let custom = DetectionModelManifest(name: "x", license: "x", inputSize: [640, 640], output: .vision, categories: ["parcel-box": .package])
        #expect(custom.category(of: "parcel-box") == .package)
    }
}
