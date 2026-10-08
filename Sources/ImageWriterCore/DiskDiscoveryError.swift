import Foundation

/// Failures while listing disks or resolving the boot disk. Any of these means the
/// caller must not show a target list (fail closed).
public enum DiskDiscoveryError: Error, Equatable, Sendable {
    /// A name from diskutil or a caller is not a valid device identifier; nothing was run.
    case invalidIdentifier(String)
    case commandFailed(command: String, status: Int32, message: String)
    case malformedOutput(command: String, detail: String)
    /// The disks backing `/` could not be determined, so no disk can be shown as safe.
    case bootDiskUnresolved(reason: String)
}

extension DiskDiscoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let name):
            return "\"\(name)\" is not a valid disk identifier."
        case .commandFailed(let command, let status, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return "\(command) failed with exit status \(status)\(detail)"
        case .malformedOutput(let command, _):
            return "\(command) returned output that could not be read."
        case .bootDiskUnresolved(let reason):
            return "Could not determine which disk macOS started from (\(reason)), so no drives are shown."
        }
    }
}
