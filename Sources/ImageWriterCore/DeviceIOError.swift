import Foundation

/// Failures while using an already opened device.
public enum DeviceIOError: Error, Equatable, Sendable {
    /// A system call failed. `code` is the errno, e.g. `ENXIO` when the drive was removed.
    case posix(operation: String, code: Int32)
    /// The handle was used after `close()`.
    case closed
    /// The device reported a block size or count that cannot be used.
    case invalidGeometry(blockSize: Int, blockCount: UInt64)
}

extension DeviceIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."
        case .closed:
            return "The drive was used after it had been closed."
        case .invalidGeometry(let blockSize, let blockCount):
            return "The drive reported an unusable size (block size \(blockSize), \(blockCount) blocks)."
        }
    }
}
