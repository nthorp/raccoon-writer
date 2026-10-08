import Foundation

/// A disk opened read-write. One handle serves both the write and the verify
/// read-back, because each privileged open costs an admin prompt (T01).
///
/// Offsets and lengths must be multiples of `blockSize`, as on a raw device;
/// violations fail with `DeviceIOError.posix(_, EINVAL)`.
public protocol OpenedDevice: AnyObject, Sendable {
    var blockSize: Int { get }
    var blockCount: UInt64 { get }

    /// Reads up to `buffer.count` bytes at `offset`. Returns the bytes read; 0 at the end of the device.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int

    /// Writes up to `buffer.count` bytes at `offset`. Returns the bytes written, which may be
    /// fewer than requested (a short write); callers retry the remainder.
    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int

    /// Flushes all written data to the medium. Returns how the flush was done.
    @discardableResult
    func fullSync() throws -> SyncMethod

    /// Releases the descriptor. Idempotent; later I/O throws `DeviceIOError.closed`.
    func close()
}

extension OpenedDevice {
    public var byteCount: UInt64 { blockCount * UInt64(blockSize) }
}
