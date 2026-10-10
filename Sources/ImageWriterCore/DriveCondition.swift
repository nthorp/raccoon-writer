import Foundation

/// What a stopped run left on the drive, for the failed and cancelled screens. The run
/// never retries, so this describes the drive as the user will find it.
public enum DriveCondition: Equatable, Sendable {
    /// Stopped before the first byte was written.
    case untouched
    /// Stopped during the write or its flush.
    case partiallyWritten
    /// Fully written, but the read-back could not finish.
    case unverified
    /// Fully written, but the read-back found data that differs from the image.
    case doesNotMatch

    /// Where a run that stopped in `stage` leaves the drive, when nothing more specific
    /// is known. Conservative: a write stopped before its first chunk still counts.
    public init(stoppedIn stage: PipelineStage) {
        switch stage {
        case .safetyCheck, .unmount, .open: self = .untouched
        case .write: self = .partiallyWritten
        // The write and its flush finished before the verify started.
        case .verify: self = .unverified
        }
    }

    public var note: String {
        switch self {
        case .untouched:
            return "Nothing was written to the drive."
        case .partiallyWritten:
            return "The drive may be partially written and is not bootable. Write the image again, or erase the drive in Disk Utility before using it."
        case .unverified:
            return "The image was written but could not be checked, so the drive may not boot. Write the image again to be sure."
        case .doesNotMatch:
            return "The drive does not hold a correct copy of the image and may not boot. Write it again, or use a different drive if this keeps happening."
        }
    }
}
