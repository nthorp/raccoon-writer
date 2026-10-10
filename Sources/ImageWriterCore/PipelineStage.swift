import Foundation

/// A step of the write pipeline that can fail or be cancelled. Closing and ejecting
/// come after these and never fail the write.
public enum PipelineStage: String, CaseIterable, Equatable, Sendable {
    case safetyCheck
    case unmount
    case open
    case write
    case verify

    public var label: String {
        switch self {
        case .safetyCheck: return "Checking the drive"
        case .unmount: return "Unmounting the drive"
        case .open: return "Getting permission to write"
        case .write: return "Writing"
        case .verify: return "Verifying"
        }
    }

    /// Whether the drive's contents may differ from before the run, if it stopped here.
    /// Conservative: a write stopped before its first chunk still counts.
    public var mayHaveModifiedDrive: Bool {
        switch self {
        case .safetyCheck, .unmount, .open: return false
        case .write, .verify: return true
        }
    }
}
