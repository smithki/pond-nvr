// Snapshots for the Home app: the first keyframe of a camera stream, decoded with VideoToolbox and saved as
// a JPEG of the size asked for. The last one is reused for a few seconds, as the Home app asks often.
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Ingest
import PondCore
import UniformTypeIdentifiers
import VideoToolbox

public final class Snapshotter: @unchecked Sendable {
    let url: String
    let username: String
    let password: String
    private var cached: (image: CGImage, at: Date)?
    /// A keyframe already at hand (a live stream's), used instead of connecting to the camera again.
    public var keyframe: (@Sendable () -> (nalus: [[UInt8]], sets: ParameterSets)?)?
    private let lock = NSLock()
    /// How long a snapshot is reused.
    static let reuse: TimeInterval = 10

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// Why the last snapshot failed, if it did.
    public var lastProblem: HomeKitStatus.Problem.Kind? { lock.withLock { problem } }
    private var problem: HomeKitStatus.Problem.Kind?

    /// A JPEG, at most `width` × `height` (keeping the camera's shape); nil if the camera gave no picture.
    public func jpeg(width: Int, height: Int) async -> [UInt8]? {
        if let c = lock.withLock({ cached }), Date().timeIntervalSince(c.at) < Self.reuse {
            return Self.encode(c.image, width: width, height: height)
        }
        let (url, username, password) = (url, username, password)
        let image: CGImage?
        if let k = keyframe?() {
            image = Self.decode(k.nalus, sets: k.sets)
        } else {
            let grabbed = await Task.detached { Self.grab(url: url, username: username, password: password) }.value
            lock.withLock { problem = grabbed.problem }
            image = grabbed.image
        }
        guard let image else { return nil }
        lock.withLock { cached = (image, Date()); problem = nil }
        return Self.encode(image, width: width, height: height)
    }

    /// Connects, waits up to 8 s for a keyframe, and decodes it; else why not.
    static func grab(url: String, username: String, password: String) -> (image: CGImage?, problem: HomeKitStatus.Problem.Kind?) {
        let session: PacketSource
        do { session = try StreamHub.shared.open(url: url, username: username, password: password, replay: true) } catch {
            return (nil, .init(error))
        }
        defer { session.close() }
        var depacketizer = VideoDepacketizer(video: session.video)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            // Nothing yet is normal: video first arrives 1–4 s after PLAY.
            let next: InterleavedPacket??
            do { next = try session.next(timeout: 1) } catch { return (nil, .init(error)) }
            guard let packet = next ?? nil else { continue }
            guard packet.channel == CameraSession.videoChannel, let rtp = RTPPacket(packet.data) else { continue }
            for unit in depacketizer.push(rtp) where unit.isKeyframe && !unit.damaged {
                guard let sets = depacketizer.parameterSets else { continue }
                let image = decode(unit.nalus, sets: sets)
                return (image, image == nil ? .other : nil)
            }
        }
        return (nil, .noVideo)
    }

    static func decode(_ nalus: [[UInt8]], sets: ParameterSets) -> CGImage? {
        guard let format = sets.formatDescription() else { return nil }
        var bytes: [UInt8] = []
        for nal in nalus {
            let n = UInt32(nal.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                    offsetIntoDestination: 0, dataLength: $0.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var size = bytes.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }

        var decoder: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &decoder) == noErr, let decoder else { return nil }
        defer { VTDecompressionSessionInvalidate(decoder) }
        // The callback only keeps the decoded buffer; the image is made after the decode has finished.
        final class Result: @unchecked Sendable { var buffer: CVImageBuffer? }
        let result = Result()
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { result.buffer = buffer }
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        guard let buffer = result.buffer else { return nil }
        return CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(
            x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }

    /// Scaled to fit `width` × `height`, as a JPEG.
    static func encode(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let scale = min(1, min(Double(width) / Double(image.width), Double(height) / Double(image.height)))
        var source = CIImage(cgImage: image)
        if scale < 1 { source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let context = CIContext()
        guard let scaled = context.createCGImage(source, from: source.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Array(data as Data)
    }
}
