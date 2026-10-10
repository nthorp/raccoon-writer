import Foundation

/// Where the app is in the select → confirm → write → verify flow. `WriteCoordinator`
/// owns the only instance and enforces the legal transitions.
public enum WriteState: Equatable, Sendable {
    case idle
    case imageSelected(ImageInfo)
    case driveSelected(ImageInfo, DiskInfo)
    case awaitingConfirmation(ImageInfo, DiskInfo)
    /// Safety check, unmount or the admin prompt; the stage says which.
    case preparing(PipelineStage)
    case writing(WriteProgress)
    case verifying(VerifyProgress)
    /// Closing and ejecting after a successful verify.
    case finishing
    case finished(WriteSummary)
    case failed(WriteFailure)
    /// Stopped at the user's request in this stage.
    case cancelled(PipelineStage)

    /// The case without its payload, for transition rules and errors.
    public enum Phase: String, Equatable, Sendable {
        case idle, imageSelected, driveSelected, awaitingConfirmation
        case preparing, writing, verifying, finishing
        case finished, failed, cancelled
    }

    public var phase: Phase {
        switch self {
        case .idle: return .idle
        case .imageSelected: return .imageSelected
        case .driveSelected: return .driveSelected
        case .awaitingConfirmation: return .awaitingConfirmation
        case .preparing: return .preparing
        case .writing: return .writing
        case .verifying: return .verifying
        case .finishing: return .finishing
        case .finished: return .finished
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// A run is in progress: the drive must not be changed and the app should not quit.
    public var isRunning: Bool {
        switch phase {
        case .preparing, .writing, .verifying, .finishing: return true
        default: return false
        }
    }
}
