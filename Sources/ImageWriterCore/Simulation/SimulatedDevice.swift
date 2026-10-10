#if DEBUG
import Foundation

/// Debug Simulate mode only. Wraps a `FileBackedDevice` and sleeps after each call so a
/// pass runs at roughly USB-stick speed and the progress screen can be watched. It can
/// also hand back one corrupted read, so the verify pass finds a mismatch.
final class SimulatedDevice: OpenedDevice, @unchecked Sendable {
    private let inner: FileBackedDevice
    private let writeBytesPerSecond: Double
    private let readBytesPerSecond: Double
    private let corruptReadCall: Int?
    private let lock = NSLock()
    private var reads = 0

    init(inner: FileBackedDevice, writeBytesPerSecond: Double, readBytesPerSecond: Double, corruptReadCall: Int? = nil) {
        self.inner = inner
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readBytesPerSecond = readBytesPerSecond
        self.corruptReadCall = corruptReadCall
    }

    var blockSize: Int { inner.blockSize }
    var blockCount: UInt64 { inner.blockCount }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try inner.read(into: buffer, at: offset)
        let call = lock.withLock { () -> Int in
            reads += 1
            return reads
        }
        if call == corruptReadCall, count > 0 {
            buffer[0] ^= 0xFF
        }
        pause(bytes: count, rate: readBytesPerSecond)
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try inner.write(from: buffer, at: offset)
        pause(bytes: count, rate: writeBytesPerSecond)
        return count
    }

    func fullSync() throws -> SyncMethod {
        // A real stick takes a moment to flush, which is when the UI says "Finishing".
        Thread.sleep(forTimeInterval: 1)
        return try inner.fullSync()
    }

    func close() {
        inner.close()
    }

    private func pause(bytes: Int, rate: Double) {
        guard rate > 0, bytes > 0 else { return }
        Thread.sleep(forTimeInterval: Double(bytes) / rate)
    }
}
#endif
