import Foundation
import os

/// Production `OpenedDevice` over a raw disk descriptor (`/dev/rdiskN`), usually
/// one handed over by authopen. Owns the descriptor and closes it.
public final class RawDevice: OpenedDevice, @unchecked Sendable {
    // <sys/disk.h> macros are not importable into Swift. Values checked against the
    // C headers in T01: _IOR('d', 24, uint32_t) and _IOR('d', 25, uint64_t).
    static let ioctlGetBlockSize: UInt = 0x4004_6418
    static let ioctlGetBlockCount: UInt = 0x4008_6419
    // Checked in T19 (arm64 and x86_64): _IOW('d', 22, dk_synchronize_t), a 24-byte struct.
    static let ioctlSynchronize: UInt = 0x8018_6416

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
                synchronize: {
                    // Zero offset and length with no options flushes the whole device.
                    var request = dk_synchronize_t()
                    return PosixIO.ioctlStatus(fd, Self.ioctlSynchronize, &request)
                },
                fullFsync: { PosixIO.fcntlStatus(fd, F_FULLFSYNC) },
                fsync: { PosixIO.fsyncStatus(fd) },
                onSkip: { skipped, code in
                    Self.log.info("fullSync skipped \(skipped.callName, privacy: .public): errno \(code) (\(String(cString: strerror(code)), privacy: .public))")
                }
            )
        }
        // The hardware runs (T12, T19) record which path a real USB stick takes.
        Self.log.info("fullSync used \(Self.logName(method), privacy: .public)")
        return method
    }

    private static func logName(_ method: SyncMethod) -> String {
        switch method {
        case .synchronize: "DKIOCSYNCHRONIZE"
        case .fullFsync: "F_FULLFSYNC"
        case .fsyncFallback: "fsync fallback"
        }
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
