import Foundation

/// Failures while obtaining a privileged handle to a disk.
public enum DeviceOpenError: Error, Equatable, Sendable {
    /// The name is not a whole-disk BSD name (`^disk[0-9]+$`); nothing was run.
    case invalidDiskName(String)
    /// The administrator prompt was cancelled.
    case userCancelled
    /// Authorization was refused or the open was not permitted.
    case permissionDenied
    /// The disk is in use (usually still mounted).
    case deviceBusy
    /// authopen failed for a reason we do not recognize. `status` is its exit code.
    case authopenFailed(status: Int32, message: String)
    /// authopen was killed by a signal before handing over a descriptor.
    case authopenTerminated(signal: Int32)
    /// Setting up the authopen call failed (socketpair, spawn, recvmsg).
    case posix(operation: String, code: Int32)
}

extension DeviceOpenError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDiskName(let name):
            return "\"\(name)\" is not a valid whole-disk name."
        case .userCancelled:
            return "The administrator password prompt was cancelled."
        case .permissionDenied:
            return "macOS did not allow the drive to be opened for writing."
        case .deviceBusy:
            return "The drive is in use. Close any files on it and try again."
        case .authopenFailed(let status, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return "Opening the drive failed (authopen exit status \(status))\(detail)."
        case .authopenTerminated(let signal):
            return "Opening the drive failed (authopen was terminated by signal \(signal))."
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}
