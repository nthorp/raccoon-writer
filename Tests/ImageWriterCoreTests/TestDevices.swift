import Foundation
@testable import ImageWriterCore

/// Lets a test hold an I/O call on its worker thread, act, then let it continue.
final class Gate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Called on the worker thread. The timeout keeps a failed test from hanging the run.
    func pass() {
        arrived.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func waitForArrival() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.arrived.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        released.signal()
    }
}

/// Forwards to a `FileBackedDevice`, but holds write call `gatedWrite` (1-based) at `gate`.
final class GatedDevice: OpenedDevice, @unchecked Sendable {
    let inner: FileBackedDevice
    let gate = Gate()
    private let gatedWrite: Int
    private let lock = NSLock()
    private var writes = 0

    init(inner: FileBackedDevice, gatedWrite: Int) {
        self.inner = inner
        self.gatedWrite = gatedWrite
    }

    var blockSize: Int { inner.blockSize }
    var blockCount: UInt64 { inner.blockCount }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try inner.read(into: buffer, at: offset)
    }

    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        let call = lock.withLock {
            writes += 1
            return writes
        }
        if call == gatedWrite { gate.pass() }
        return try inner.write(from: buffer, at: offset)
    }

    func fullSync() throws -> SyncMethod { try inner.fullSync() }
    func close() { inner.close() }
}

/// A device that accepts every write but stores nothing, reporting 0 bytes written.
final class ZeroWriteDevice: OpenedDevice, @unchecked Sendable {
    let blockSize = 512
    let blockCount: UInt64 = 64
    private let lock = NSLock()
    private var syncs = 0

    var syncCallCount: Int { lock.withLock { syncs } }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int { 0 }
    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int { 0 }

    func fullSync() throws -> SyncMethod {
        lock.withLock { syncs += 1 }
        return .fullFsync
    }

    func close() {}
}
