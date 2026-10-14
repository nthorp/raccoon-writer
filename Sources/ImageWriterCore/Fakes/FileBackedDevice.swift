import Foundation

/// An `OpenedDevice` backed by a temporary file, for tests and the debug "Simulate" mode.
/// Emulates the raw-device rules seen in T01 and supports failure injection.
public final class FileBackedDevice: OpenedDevice, @unchecked Sendable {
    /// Fail the Nth call (1-based) of an operation with errno `code`.
    public struct InjectedFailure: Equatable, Sendable {
        public var call: Int
        public var code: Int32

        public init(call: Int, code: Int32 = EIO) {
            self.call = call
            self.code = code
        }
    }

    public struct Faults: Equatable, Sendable {
        public var failWrite: InjectedFailure?
        public var failRead: InjectedFailure?
        /// On this write call (1-based), write about half the request, rounded down to a
        /// block multiple and at least one block. A one-block request is written in full.
        public var shortWriteOnCall: Int?
        /// The same as `shortWriteOnCall`, for read calls.
        public var shortReadOnCall: Int?
        /// errno returned by every sync attempt.
        public var syncError: Int32?
        /// Make `F_FULLFSYNC` fail with `ENOTTY`, like the T01 RAM disk, to exercise the fallback.
        public var fullFsyncUnsupported: Bool

        public init(
            failWrite: InjectedFailure? = nil,
            failRead: InjectedFailure? = nil,
            shortWriteOnCall: Int? = nil,
            shortReadOnCall: Int? = nil,
            syncError: Int32? = nil,
            fullFsyncUnsupported: Bool = false
        ) {
            self.failWrite = failWrite
            self.failRead = failRead
            self.shortWriteOnCall = shortWriteOnCall
            self.shortReadOnCall = shortReadOnCall
            self.syncError = syncError
            self.fullFsyncUnsupported = fullFsyncUnsupported
        }
    }

    public let url: URL
    public let blockSize: Int
    public let blockCount: UInt64

    private let lock = NSLock()
    private var fd: Int32?
    private var currentFaults: Faults
    private var writes = 0
    private var reads = 0
    private var syncs = 0
    private var closes = 0
    private var lastSync: SyncMethod?

    /// Creates a zero-filled backing file of `blockSize * blockCount` bytes in `directory`.
    /// The file is deleted when the device is deallocated.
    public init(
        blockSize: Int,
        blockCount: UInt64,
        faults: Faults = Faults(),
        directory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard BlockMath.isValidGeometry(blockSize: blockSize, blockCount: blockCount),
              let size = off_t(exactly: blockCount * UInt64(blockSize)) else {
            throw DeviceIOError.invalidGeometry(blockSize: blockSize, blockCount: blockCount)
        }
        let url = directory.appendingPathComponent("raccoonwriter-fake-\(UUID().uuidString).img")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DeviceIOError.posix(operation: "open", code: errno) }
        guard ftruncate(fd, size) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(url.path)
            throw DeviceIOError.posix(operation: "ftruncate", code: code)
        }
        self.url = url
        self.fd = fd
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.currentFaults = faults
    }

    deinit {
        close()
        // Best-effort temp file cleanup; a leftover file in the temp directory is harmless.
        unlink(url.path)
    }

    // MARK: - Inspection

    public var faults: Faults {
        get { lock.withLock { currentFaults } }
        set { lock.withLock { currentFaults = newValue } }
    }

    public var writeCallCount: Int { lock.withLock { writes } }
    public var readCallCount: Int { lock.withLock { reads } }
    public var syncCallCount: Int { lock.withLock { syncs } }
    public var closeCallCount: Int { lock.withLock { closes } }
    public var isClosed: Bool { lock.withLock { fd == nil } }
    /// The method of the last successful `fullSync()`, or nil if none succeeded.
    public var lastSyncMethod: SyncMethod? { lock.withLock { lastSync } }

    /// The whole backing file; readable after `close()`.
    public func contents() throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: - OpenedDevice

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try lock.withLock {
            guard let fd else { throw DeviceIOError.closed }
            reads += 1
            try checkAlignment(offset: offset, length: buffer.count, operation: "read")
            if let failure = currentFaults.failRead, failure.call == reads {
                throw DeviceIOError.posix(operation: "read at offset \(offset)", code: failure.code)
            }
            var length = clampedLength(buffer.count, at: offset)
            guard length > 0 else { return 0 }
            if currentFaults.shortReadOnCall == reads, length > blockSize {
                length = Self.shortened(length, blockSize: blockSize)
            }
            return try PosixIO.pread(fd, into: UnsafeMutableRawBufferPointer(rebasing: buffer[..<length]), at: offset)
        }
    }

    public func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try lock.withLock {
            guard let fd else { throw DeviceIOError.closed }
            writes += 1
            try checkAlignment(offset: offset, length: buffer.count, operation: "write")
            if let failure = currentFaults.failWrite, failure.call == writes {
                throw DeviceIOError.posix(operation: "write at offset \(offset)", code: failure.code)
            }
            var length = clampedLength(buffer.count, at: offset)
            guard length > 0 || buffer.isEmpty else {
                // Writing at or past the end of a raw device fails rather than growing it.
                throw DeviceIOError.posix(operation: "write at offset \(offset)", code: ENOSPC)
            }
            if currentFaults.shortWriteOnCall == writes, length > blockSize {
                length = Self.shortened(length, blockSize: blockSize)
            }
            return try PosixIO.pwrite(fd, from: UnsafeRawBufferPointer(rebasing: buffer[..<length]), at: offset)
        }
    }

    @discardableResult
    public func fullSync() throws -> SyncMethod {
        try lock.withLock {
            guard let fd else { throw DeviceIOError.closed }
            syncs += 1
            let faults = currentFaults
            let method = try SyncMethod.perform(
                fullFsync: {
                    if faults.fullFsyncUnsupported { return ENOTTY }
                    return faults.syncError ?? PosixIO.fcntlStatus(fd, F_FULLFSYNC)
                },
                fsync: { faults.syncError ?? PosixIO.fsyncStatus(fd) }
            )
            lastSync = method
            return method
        }
    }

    public func close() {
        lock.withLock {
            closes += 1
            guard let fd else { return }
            self.fd = nil
            Darwin.close(fd)
        }
    }

    // MARK: - Raw-device emulation

    /// T01: a raw node rejects a length or offset that is not a block multiple with EINVAL.
    private func checkAlignment(offset: UInt64, length: Int, operation: String) throws {
        guard BlockMath.isAligned(offset, to: blockSize), BlockMath.isAligned(length, to: blockSize) else {
            throw DeviceIOError.posix(operation: "\(operation) at offset \(offset)", code: EINVAL)
        }
    }

    /// About half of `length`, rounded down to a block multiple and at least one block.
    private static func shortened(_ length: Int, blockSize: Int) -> Int {
        max(blockSize, length / 2 / blockSize * blockSize)
    }

    /// How much of a request at `offset` lies inside the device.
    private func clampedLength(_ length: Int, at offset: UInt64) -> Int {
        let byteCount = blockCount * UInt64(blockSize)
        guard offset < byteCount else { return 0 }
        return Int(min(UInt64(length), byteCount - offset))
    }
}
