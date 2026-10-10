import Foundation

/// Why `SafetyGuard` refused to let a write start. Nothing has been unmounted or
/// opened when any of these is thrown.
public enum SafetyGuardError: Error, Equatable, Sendable {
    /// The confirmed disk is no longer listed, usually because it was removed.
    case diskMissing(bsdName: String)
    /// A disk with the confirmed name is present, but it is not the confirmed one.
    case diskChanged(bsdName: String, field: DiskIdentityField)
    /// The disk is no longer an allowed target under the setting the user chose.
    case forbiddenTarget(bsdName: String, reason: DiskRejection)
    /// The disks or the boot disk could not be queried, so nothing can be shown safe.
    case queryFailed(reason: String)
}

extension SafetyGuardError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .diskMissing(let bsdName):
            return "The drive (\(bsdName)) can no longer be found. It may have been removed. Nothing was written."
        case .diskChanged(let bsdName, let field):
            return "The drive at \(bsdName) is not the one you confirmed (its \(field.label) changed). Nothing was written. Select the drive again."
        case .forbiddenTarget(let bsdName, let reason):
            return "The drive (\(bsdName)) can't be written: \(reason.explanation) Nothing was written."
        case .queryFailed(let reason):
            return "The drive could not be checked again before writing, so nothing was written. (\(reason))"
        }
    }
}
