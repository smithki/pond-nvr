import CoreGraphics
import Foundation
import Testing
@testable import Understanding

@Suite struct BPETokenizerTests {
    static let tiny = try! BPETokenizer(contentsOf: Bundle.module.url(forResource: "tiny-tokenizer", withExtension: "json",
                                                                       subdirectory: "Fixtures")!)

    @Test func pairsAreJoinedBestFirst() {
        // "a cat": a, then ▁ c a t joined (c+a, ca+t, ▁+cat) into ▁cat.
        #expect(Self.tiny.encode("a cat") == [10, 16])
        #expect(Self.tiny.encode("cats") == [15, 17])
    }

    @Test func whatTheVocabularyLacksIsSpelledInBytes() {
        // é: not in it; its UTF-8 bytes are.
        #expect(Self.tiny.encode("é") == [20, 21])
        // x: nor its byte: unknown.
        #expect(Self.tiny.encode("x") == [3])
    }

    @Test func idsEndAndArePaddedToTheirLength() {
        #expect(Self.tiny.ids("a cat", length: 5) == [10, 16, 1, 0, 0])
        // Too long: cut, the end token kept. (" a" isn't a token: "▁", then "a".)
        #expect(Self.tiny.ids("a cat a cat a cat", length: 4) == [10, 16, 11, 1])
    }
}

/// The real model's folder (models/search, made by scripts/convert-siglip.py; not in the repository), if it's there.
let searchModels: URL? = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../models/search").standardized
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("siglip2.json").path) ? url : nil
}()

/// The real model: run when it's there.
@Suite(.enabled(if: searchModels != nil)) struct SigLIPTests {
    static var folder: URL? { searchModels }

    /// Loaded once for them all.
    static let siglip: SigLIP? = folder.flatMap { try? SigLIP(folder: $0) }

    @Test func itsTokensAreTheModelsOwn() throws {
        let siglip = try #require(Self.siglip)
        for reference in siglip.manifest.references ?? [] {
            #expect(siglip.ids(reference.text) == reference.ids, "\(reference.text)")
        }
    }

    /// Pictures are given to it as its own code gives them: their colours in order, scaled alike.
    @Test func itsPicturesAreEmbeddedAsTheModelsOwnCodeDoes() throws {
        let siglip = try #require(Self.siglip)
        let reference = try #require(siglip.manifest.pictureReference)
        let size = siglip.manifest.imageSize
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                bytes[i] = UInt8((Double(x) * 255 / Double(size - 1)).rounded())
                bytes[i + 1] = UInt8((Double(y) * 255 / Double(size - 1)).rounded())
                bytes[i + 2] = 128
                bytes[i + 3] = 255
            }
        }
        let context = try #require(CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let picture = try #require(context.makeImage())
        let embedding = try siglip.embed(picture)
        // As the converted encoder makes it from the same picture: all but equal (a picture given wrongly, its
        // colours swapped or scaled otherwise, is far off).
        #expect(SigLIP.similarity(embedding, try #require(reference.converted)) > 0.999)
        // And near the original's (the encoder's quantized, and this picture's like no camera's, so only near).
        #expect(SigLIP.similarity(embedding, reference.embedding) > 0.9)
    }

    @Test func itsPhrasesAreEmbeddedAsTheModelsOwnCodeDoes() throws {
        let siglip = try #require(Self.siglip)
        for reference in siglip.manifest.references ?? [] {
            // (Quantized, so near, not equal.)
            #expect(SigLIP.similarity(try siglip.embed(reference.text), reference.embedding) > 0.99, "\(reference.text)")
        }
    }
}

@Suite struct DescriberTests {
    @Test func whatWasFoundIsSaidPlainly() {
        #expect(Describer.words(["person": 2, "cat": 1]) == "a cat, 2 persons")
        #expect(Describer.words([:]) == "")
    }

    @Test func aSentenceIsTidied() {
        #expect(Describer.tidy("  \"A cat on the sofa.\"\n") == "A cat on the sofa.")
        #expect(Describer.tidy("A dog.\nIt is brown.") == "A dog.")
    }
}

@Suite struct CloseUpTests {
    static func picture(_ w: Int, _ h: Int) -> CGImage {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @Test func aSmallSubjectGetsASquareThirdOfThePictureRoundIt() throws {
        // 1000×600, a person 30×90 at (500, 300): a square 200 a side (a third of 600), round them.
        let crop = try #require(CloseUp.crop(Self.picture(1000, 600), box: CGRect(x: 0.485, y: 0.425, width: 0.03, height: 0.15)))
        #expect(crop.width == 200 && crop.height == 200)
    }

    @Test func itStaysInsideThePicture() throws {
        // At the very corner: the square's moved in, not cut.
        let crop = try #require(CloseUp.crop(Self.picture(1000, 600), box: CGRect(x: 0, y: 0, width: 0.02, height: 0.05)))
        #expect(crop.width == 200 && crop.height == 200)
    }

    @Test func aSubjectFillingThePictureNeedsNone() {
        #expect(CloseUp.crop(Self.picture(1000, 600), box: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.8)) == nil)
    }
}

/// Questions read at a fixed moment: Tuesday 20 October 2026, 14:00, in a fixed time zone (weeks from Sunday).
@Suite struct TimeWordsTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Denver")!
        c.firstWeekday = 1
        return c
    }()
    static func at(_ day: Int, _ hour: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    static let now = at(20, 14)
    static func range(_ text: String) -> ClosedRange<Date>? { TimeWords.find(in: text, now: now, calendar: calendar)?.filter.range }

    @Test func daysAndTheirParts() {
        #expect(Self.range("today") == Self.at(20, 0) ... Self.now)
        #expect(Self.range("yesterday") == Self.at(19, 0) ... Self.at(20, 0))
        #expect(Self.range("last night") == Self.at(19, 20) ... Self.at(20, 6))
        #expect(Self.range("this morning") == Self.at(20, 5) ... Self.at(20, 12))
        #expect(Self.range("yesterday afternoon") == Self.at(19, 12) ... Self.at(19, 17))
        // Not begun yet: empty, at its start.
        #expect(Self.range("this evening") == Self.at(20, 17) ... Self.at(20, 17))
    }

    @Test func weekdays() {
        #expect(Self.range("on monday") == Self.at(19, 0) ... Self.at(20, 0))
        #expect(Self.range("friday night") == Self.at(16, 20) ... Self.at(17, 6))
        // Today's name: today.
        #expect(Self.range("tuesday") == Self.at(20, 0) ... Self.now)
        #expect(Self.range("last tuesday") == Self.at(13, 0) ... Self.at(14, 0))
    }

    @Test func stretchesBackFromNow() {
        #expect(Self.range("in the last 3 hours") == Self.at(20, 11) ... Self.now)
        #expect(Self.range("past two days") == Self.now.addingTimeInterval(-2 * 86400) ... Self.now)
        #expect(Self.range("this week") == Self.at(18, 0) ... Self.now)
        #expect(Self.range("last week") == Self.at(11, 0) ... Self.at(18, 0))
        #expect(Self.range("two days ago") == Self.at(18, 0) ... Self.at(19, 0))
    }

    @Test func aPartOfEveryDay() throws {
        let night = try #require(TimeWords.find(in: "cats at night", now: Self.now, calendar: Self.calendar)?.filter)
        #expect(night.range == nil && night.hours == .init(from: 20, to: 6))
        #expect(night.contains(Self.at(3, 23), calendar: Self.calendar) && !night.contains(Self.at(3, 12), calendar: Self.calendar))
    }

    @Test func noTimeSaid() {
        #expect(TimeWords.find(in: "a man in a red jacket", now: Self.now, calendar: Self.calendar) == nil)
    }
}

@Suite struct PlainReaderTests {
    static func read(_ q: String) -> EventQuery {
        PlainReader.read(q, cameras: ["Front Door", "Living Room"], zones: ["Driveway"], now: TimeWordsTests.now,
                         calendar: TimeWordsTests.calendar)
    }

    @Test func kindsThingsAndPlaces() {
        let q = Self.read("cats in the Living Room last night")
        #expect(q.kinds == ["animal"] && q.things == ["cat"])
        #expect(q.cameras == ["Living Room"])
        #expect(q.time.range == TimeWordsTests.at(19, 20) ... TimeWordsTests.at(20, 6))
        // Nothing said of how they looked.
        #expect(q.appearance == nil)
    }

    @Test func howTheyLookedIsKeptForThePictures() {
        let q = Self.read("a man in a red jacket at the Front Door")
        #expect(q.kinds == ["person"] && q.cameras == ["Front Door"])
        #expect(q.appearance == "man in a red jacket")
    }

    @Test func aBagCarriedIsntOneLeft() {
        #expect(Self.read("someone carrying a bag").kinds == ["person"])
        #expect(Self.read("a bag left in the Driveway").kinds == ["item"])
    }

    @Test func deliveriesAndTheDoorbell() {
        #expect(Self.read("packages delivered this week").kinds == ["package"])
        #expect(Self.read("who rang the doorbell yesterday").kinds == ["ring"])
        #expect(Self.read("trucks in the Driveway").zones == ["Driveway"])
    }
}

/// What the Mac's model reads is held to the question: it fills in what it's offered.
@Suite struct QuestionMergeTests {
    static let cameras = ["Front Door", "Living Room"], zones = ["Driveway", "TV"]

    static func merged(_ question: String, _ read: ReadQuestion) -> EventQuery {
        let plain = PlainReader.read(question, cameras: cameras, zones: zones, now: TimeWordsTests.now, calendar: TimeWordsTests.calendar)
        return QuestionReader.merge(read, plain: plain, question: question, cameras: cameras, zones: zones, now: TimeWordsTests.now,
                                    calendar: TimeWordsTests.calendar)
    }

    @Test func camerasZonesAndTimesNotInTheQuestionAreLeftOut() {
        let q = Self.merged("a person carrying a bag",
                            ReadQuestion(kinds: ["person", "item", "doorbell"], things: ["bag", "school bus"], cameras: ["Front Door", "Living Room"],
                                         zones: ["TV"], when: "last night", appearance: "a person carrying a bag"))
        #expect(q.cameras.isEmpty && q.zones.isEmpty && q.time.isEmpty)
        // The question's own kind (a person: a bag carried isn't one left), not the doorbell.
        #expect(q.kinds == ["person"])
        #expect(q.appearance == "a person carrying a bag")
    }

    @Test func whatItReadOfTheQuestionIsKept() {
        let q = Self.merged("a mail carrier at the front door yesterday",
                            ReadQuestion(kinds: ["person"], things: [], cameras: ["Front Door"], zones: [], when: "yesterday",
                                         appearance: "a mail carrier"))
        #expect(q.kinds == ["person"] && q.cameras == ["Front Door"])
        #expect(q.time.range == TimeWordsTests.at(19, 0) ... TimeWordsTests.at(20, 0))
        #expect(q.appearance == "a mail carrier")
    }

    @Test func anAppearanceThatOnlySaysWhatAndWhereIsNone() {
        let q = Self.merged("cats in the living room",
                            ReadQuestion(kinds: ["animal"], things: ["cat"], cameras: ["Living Room"], zones: [], when: "",
                                         appearance: "cats in the living room"))
        #expect(q.appearance == nil && q.things == ["cat"])
    }
}
