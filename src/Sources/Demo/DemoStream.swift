// A demo camera's stream, as a camera's RTSP session gives one (a PacketSource): each picture drawn when it's due
// (DemoPainter), encoded on the Mac's video hardware, and sent as RTP (H.264, 90 kHz, its parameter sets in band
// before each keyframe), with a sender report every couple of seconds tying its times to the clock, as cameras do.
// StreamHub opens it for a `demo://` address (DemoStream.register), so everything that reads a camera reads it.
import CoreMedia
import CoreVideo
import Foundation
import HAPCamera
import Ingest
import NVRCore
import VideoToolbox

public final class DemoStream: PacketSource, @unchecked Sendable {
    public private(set) var video: SDP.Media
    public let audio: SDP.Media? = nil
    let id: String
    let world: DemoWorld
    let painter: DemoPainter
    let fps: Double
    let keyframeEvery: TimeInterval
    private let encoder: VTCompressionSession
    private var pool: CVPixelBufferPool?
    private var packetizer: RTPPacketizer
    private var pending: [InterleavedPacket] = []
    private var due = Date()
    private var lastKeyframe = Date.distantPast
    private var lastReport = Date.distantPast
    private var sentPackets: UInt32 = 0, sentOctets: UInt32 = 0
    /// For a camera that keeps dropping: when this connection ends.
    private let dropsAt: Date?
    private var closed = false

    /// Every `demo://` stream opened through StreamHub from now on: this process's demo world's.
    public static func register() {
        StreamHub.openers[Demo.scheme] = { try DemoStream(url: $0) }
    }

    public init(url: String, world: DemoWorld? = DemoWorld.current) throws(RTSPError) {
        guard let world, let (id, scenario, main) = Demo.parse(url), scenario == world.scenario.name,
              let camera = world.camera(id) else { throw .notFound(url) }
        // Restarting: nothing answers for now.
        guard !world.isRestarting(id) else { throw .transport(.refused("\(camera.name) is restarting")) }
        self.id = id
        self.world = world
        let size = main ? camera.mainSize : camera.subSize
        painter = DemoPainter(camera: camera, world: world, width: size.width, height: size.height)
        fps = main ? 15 : 10
        keyframeEvery = camera.trouble == .slowKeyframes ? 12 : 2
        dropsAt = camera.trouble == .drops ? Date().addingTimeInterval(.random(in: 90 ... 240)) : nil
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else {
            throw .malformed("no H.264 encoder for \(size.width)×\(size.height)")
        }
        encoder = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: (keyframeEvery * 1.5) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (main ? 2_500_000 : 400_000) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        packetizer = RTPPacketizer(payloadType: 96, ssrc: .random(in: 1 ... .max), maxPayload: 1400)
        // The first picture encoded now, for the parameter sets the description carries.
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size.width,
                          kCVPixelBufferHeightKey as String: size.height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        CVPixelBufferPoolCreate(nil, nil, attributes, &pool)
        video = SDP("m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:trackID=0\r\n").video!
        guard let first = encode(at: Date(), keyframe: true), let sps = first.sps, let pps = first.pps else {
            VTCompressionSessionInvalidate(session)
            throw .malformed("the demo camera's first picture couldn't be encoded")
        }
        var described = video
        described.format["sprop-parameter-sets"] = Data(sps).base64EncodedString() + "," + Data(pps).base64EncodedString()
        video = described
        queue(first.nalus, at: first.time)
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        closed = true
        VTCompressionSessionInvalidate(encoder)
    }

    public func next(timeout: Double) throws(RTSPError) -> InterleavedPacket? {
        if !pending.isEmpty { return pending.removeFirst() }
        guard !closed else { throw .transport(.closed) }
        if world.isRestarting(id) { throw .transport(.closed) }
        if let dropsAt, Date() > dropsAt { throw .transport(.failed("the demo camera dropped its connection")) }
        let wait = due.timeIntervalSinceNow
        if wait > timeout {
            Thread.sleep(forTimeInterval: max(0, timeout))
            return nil
        }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let now = Date()
        // Behind (a pause): on from now, not every picture missed.
        due = max(due.addingTimeInterval(1 / fps), now.addingTimeInterval(-1 / fps))
        let keyframe = now.timeIntervalSince(lastKeyframe) >= keyframeEvery
        guard let frame = encode(at: now, keyframe: keyframe) else { return nil }
        queue(frame.nalus, at: frame.time)
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// RTP time (90 kHz) for a moment.
    static func rtpTime(_ t: Date) -> UInt32 { UInt32(truncatingIfNeeded: Int64(t.timeIntervalSince1970 * 90000)) }

    private func queue(_ nalus: [[UInt8]], at t: Date) {
        let ts = Self.rtpTime(t)
        for packet in packetizer.packetize(nalus, timestamp: ts) {
            pending.append(InterleavedPacket(channel: CameraSession.videoChannel, data: packet))
            sentPackets &+= 1
            sentOctets &+= UInt32(packet.count - 12)
        }
        if t.timeIntervalSince(lastReport) >= 2 {
            lastReport = t
            pending.append(InterleavedPacket(channel: CameraSession.videoChannel + 1, data: senderReport(at: t, rtp: ts)))
        }
    }

    /// RTCP's sender report: the camera's clock (NTP) for an RTP time.
    private func senderReport(at t: Date, rtp: UInt32) -> [UInt8] {
        let clock = world.drifted(id, t).timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(truncatingIfNeeded: Int64(clock))
        let fraction = UInt32(truncatingIfNeeded: Int64((clock - clock.rounded(.down)) * 4_294_967_296))
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        return [0x80, 200, 0, 6] + be(packetizer.ssrc) + be(seconds) + be(fraction) + be(rtp) + be(sentPackets) + be(sentOctets)
    }

    private struct Encoded {
        var nalus: [[UInt8]]
        var sps: [UInt8]?
        var pps: [UInt8]?
        var time: Date
    }

    /// The picture at `t`, drawn and encoded (its parameter sets first, for a keyframe).
    private func encode(at t: Date, keyframe: Bool) -> Encoded? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        painter.paint(buffer, at: t)
        final class Out: @unchecked Sendable { var sample: CMSampleBuffer? }
        let out = Out()
        let pts = CMTime(value: Int64(t.timeIntervalSince1970 * 90000), timescale: 90000)
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            if status == noErr { out.sample = sample }
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: pts)
        guard let sample = out.sample else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var nalus = Self.nalus(of: sample)
        var sets: [[UInt8]] = []
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0 ..< 2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append([UInt8](UnsafeBufferPointer(start: pointer, count: size)))
                }
            }
            nalus = sets + nalus
            lastKeyframe = t
        }
        return Encoded(nalus: nalus, sps: sets.first, pps: sets.count > 1 ? sets[1] : nil, time: t)
    }

    /// A sample's NAL units (4-byte lengths in, units out).
    static func nalus(of sample: CMSampleBuffer) -> [[UInt8]] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return [] }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        var nalus: [[UInt8]] = []
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= bytes.count else { break }
            nalus.append(Array(bytes[i ..< i + n]))
            i += n
        }
        return nalus
    }
}
