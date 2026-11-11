// SPDX-License-Identifier: MIT
// A transport made worse on purpose: what it sends is delayed, sometimes lost, and squeezed through a bottleneck of
// a given rate (its queue a fifth of a second long, the rest dropped), as a slow link far away would. Demo mode's
// "slow second home"; real sessions never use it.
import Foundation

public final class ShapedTransport: PacketTransport, @unchecked Sendable {
    public struct Shape: Sendable, Equatable {
        /// One way, seconds.
        public var delay: Double
        public var loss: Double
        /// Bytes a second (nil: no limit).
        public var rate: Double?

        public init(delay: Double, loss: Double, rate: Double?) {
            self.delay = delay
            self.loss = loss
            self.rate = rate
        }
    }

    let inner: PacketTransport
    let shape: Shape
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "shaped transport")
    /// When the bottleneck is free again.
    private var freeAt = Date.distantPast

    public init(_ inner: PacketTransport, shape: Shape) {
        self.inner = inner
        self.shape = shape
    }

    public var port: UInt16 { inner.port }

    public func send(_ bytes: [UInt8], to destination: STUNAddress) {
        guard Double.random(in: 0 ..< 1) >= shape.loss else { return }
        let wait: Double? = lock.withLock {
            guard let rate = shape.rate else { return shape.delay }
            let now = Date()
            let start = max(now, freeAt)
            // A full queue: dropped, as a router's would.
            guard start.timeIntervalSince(now) < 0.2 else { return nil }
            freeAt = start.addingTimeInterval(Double(bytes.count) / rate)
            return freeAt.timeIntervalSince(now) + shape.delay
        }
        guard let wait else { return }
        let inner = inner
        queue.asyncAfter(deadline: .now() + wait) { inner.send(bytes, to: destination) }
    }

    public func receive(_ handler: @escaping @Sendable ([UInt8], STUNAddress) -> Void) { inner.receive(handler) }

    public func close() { inner.close() }
}
