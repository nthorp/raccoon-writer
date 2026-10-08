import Foundation

/// How `OpenedDevice.fullSync()` flushed the device.
public enum SyncMethod: Equatable, Sendable {
    /// `F_FULLFSYNC` succeeded: the drive was asked to flush its own cache.
    case fullFsync
    /// The device does not support `F_FULLFSYNC` (T01: RAM disks return `ENOTTY`), so `fsync` was used.
    case fsyncFallback

    /// Runs `F_FULLFSYNC`, falling back to `fsync` only when it is unsupported.
    /// Each closure performs the call and returns 0 or an errno.
    static func perform(fullFsync: () -> Int32, fsync: () -> Int32) throws -> SyncMethod {
        var code = fullFsync()
        while code == EINTR { code = fullFsync() }
        if code == 0 { return .fullFsync }
        guard code == ENOTTY || code == ENOTSUP else {
            throw DeviceIOError.posix(operation: "F_FULLFSYNC", code: code)
        }
        var fallback = fsync()
        while fallback == EINTR { fallback = fsync() }
        guard fallback == 0 else { throw DeviceIOError.posix(operation: "fsync", code: fallback) }
        return .fsyncFallback
    }
}
