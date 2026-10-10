import Foundation

/// Failures to unmount or eject a disk. A diskutil that can't be run at all surfaces as
/// `CommandRunnerError` instead.
public enum DiskManagerError: Error, Equatable, Sendable {
    /// The name is not a whole-disk BSD name (`^disk[0-9]+$`); nothing was run.
    case invalidDiskName(String)
    /// A volume on the disk is in use. `dissenter` is the path of the process that
    /// refused, when diskutil names one.
    case busy(dissenter: String?)
    /// diskutil has no such disk, usually because it was removed.
    case notFound(bsdName: String)
    /// diskutil failed for a reason we don't recognize. `output` is its stdout and stderr.
    case commandFailed(command: String, status: Int32, output: String)
}

extension DiskManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDiskName(let name):
            return "\"\(name)\" is not a valid whole-disk name."
        case .busy(let dissenter?):
            let app = URL(fileURLWithPath: dissenter).lastPathComponent
            return "The drive is in use by \(app). Quit it or close any files on the drive, then try again."
        case .busy(nil):
            return "The drive is in use. Close any files on it and try again."
        case .notFound(let bsdName):
            return "The drive (\(bsdName)) could not be found. It may have been removed."
        case .commandFailed(let command, let status, let output):
            let detail = output.isEmpty ? "" : ": \(output)"
            return "\(command) failed with exit status \(status)\(detail)"
        }
    }
}
