import Foundation
import os

/// Production `OpenedDevice` over a raw disk descriptor (`/dev/rdiskN`), usually
/// one handed over by authopen. Owns the descriptor and closes it.
public final class RawDevice: OpenedDevice, @unchecked Sendable {
    // <sys/disk.h> macros are not importable into Swift. Values checked against the
    // C headers in T01: _IOR('d', 24, uint32_t) and _IOR('d', 25, uint64_t).
    static let ioctlGetBlockSize: UInt = 0x4004_6418
    static let ioctlGetBlockCount: UInt = 0x4008_6419

    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "device")

    public let blockSize: Int
    public let blockCount: UInt64

    // The lock is held across each I/O call so `close()` can never release the
    // descriptor number mid-call, where it could be reused for an unrelated file.
    private let lock = NSLock()
    private var fd: Int32?

    /// Takes ownership of `fd`: queries its geometry and disables caching.
    /// On failure the descriptor is left open for the caller to close.
    public convenience init(fd: Int32) throws {
        var blockSize: UInt32 = 0
        var blockCount: UInt64 = 0
        guard ioctl(fd, Self.ioctlGetBlockSize, &blockSize) == 0 else {
            throw DeviceIOError.posix(operation: "ioctl(DKIOCGETBLOCKSIZE)", code: errno)
        }
        guard ioctl(fd, Self.ioctlGetBlockCount, &blockCount) == 0 else {
            throw DeviceIOError.posix(operation: "ioctl(DKIOCGETBLOCKCOUNT)", code: errno)
        }
        try self.init(fd: fd, blockSize: Int(blockSize), blockCount: blockCount)
        // Raw nodes bypass the buffer cache already; this keeps a block node honest too.
        if fcntl(fd, F_NOCACHE, 1) == -1 {
            Self.log.notice("F_NOCACHE failed with errno \(errno)")
        }
    }

    /// Geometry supplied directly, so tests can drive a regular file through this type.
    init(fd: Int32, blockSize: Int, blockCount: UInt64) throws {
        guard BlockMath.isValidGeometry(blockSize: blockSize, blockCount: blockCount) else {
            throw DeviceIOError.invalidGeometry(blockSize: blockSize, blockCount: blockCount)
        }
        self.fd = fd
        self.blockSize = blockSize
        self.blockCount = blockCount
    }

    deinit { close() }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try withDescriptor { try PosixIO.pread($0, into: buffer, at: offset) }
    }

    public func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try withDescriptor { try PosixIO.pwrite($0, from: buffer, at: offset) }
    }

    @discardableResult
    public func fullSync() throws -> SyncMethod {
        let method = try withDescriptor { fd in
            try SyncMethod.perform(
                fullFsync: { PosixIO.fcntlStatus(fd, F_FULLFSYNC) },
                fsync: { PosixIO.fsyncStatus(fd) }
            )
        }
        // T12 records which path a real USB stick takes.
        Self.log.info("fullSync used \(method == .fullFsync ? "F_FULLFSYNC" : "fsync fallback", privacy: .public)")
        return method
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard let fd else { return }
        self.fd = nil
        if Darwin.close(fd) == -1 {
            Self.log.error("close(\(fd)) failed with errno \(errno)")
        }
    }

    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let fd else { throw DeviceIOError.closed }
        return try body(fd)
    }
}
