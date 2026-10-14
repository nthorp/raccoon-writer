import Foundation

/// How `OpenedDevice.fullSync()` flushed the device.
public enum SyncMethod: Equatable, Sendable {
    /// `DKIOCSYNCHRONIZE` succeeded: the disk driver sent the drive a SYNCHRONIZE CACHE,
    /// so the drive was asked to empty its write cache. The expected path on a raw disk node.
    case synchronize
    /// `F_FULLFSYNC` succeeded. A filesystem turns it into a drive cache flush, so this is
    /// the path for regular files and the fakes; a raw disk node returns `ENOTTY` (T01, T12).
    case fullFsync
    /// Neither flush command is supported, so `fsync` was used. On a raw node (`/dev/rdiskN`)
    /// this returns 0 without reaching the drive; the eject that follows flushes it.
    case fsyncFallback

    /// The call's name, for errors and logs.
    var callName: String {
        switch self {
        case .synchronize: "ioctl(DKIOCSYNCHRONIZE)"
        case .fullFsync: "F_FULLFSYNC"
        case .fsyncFallback: "fsync"
        }
    }

    /// Runs `DKIOCSYNCHRONIZE`, then `F_FULLFSYNC`, then `fsync`, moving on only when a
    /// call reports it is unsupported. Each closure performs the call and returns 0 or an errno.
    /// `onSkip` hears about each unsupported call, so a hardware run can show why.
    static func perform(
        synchronize: () -> Int32,
        fullFsync: () -> Int32,
        fsync: () -> Int32,
        onSkip: (SyncMethod, Int32) -> Void = { _, _ in }
    ) throws -> SyncMethod {
        let synchronizeCode = retryingInterrupts(synchronize)
        if synchronizeCode == 0 { return .synchronize }
        try skip(.synchronize, code: synchronizeCode, onSkip: onSkip)

        let fullFsyncCode = retryingInterrupts(fullFsync)
        if fullFsyncCode == 0 { return .fullFsync }
        try skip(.fullFsync, code: fullFsyncCode, onSkip: onSkip)

        // Reaching fsync is not an error: RAM disks may support neither flush command.
        let fsyncCode = retryingInterrupts(fsync)
        guard fsyncCode == 0 else { throw DeviceIOError.posix(operation: SyncMethod.fsyncFallback.callName, code: fsyncCode) }
        return .fsyncFallback
    }

    private static func retryingInterrupts(_ call: () -> Int32) -> Int32 {
        var code = call()
        while code == EINTR { code = call() }
        return code
    }

    /// Only "unsupported" moves on to the next method; any other error is a real sync failure.
    private static func skip(_ method: SyncMethod, code: Int32, onSkip: (SyncMethod, Int32) -> Void) throws {
        guard code == ENOTTY || code == ENOTSUP else {
            throw DeviceIOError.posix(operation: method.callName, code: code)
        }
        onSkip(method, code)
    }
}
