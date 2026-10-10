import Foundation

/// A coordinator call was refused. Nothing changed.
public enum WriteCoordinatorError: Error, Equatable, Sendable {
    public enum Action: String, Sendable {
        case selectImage, selectDrive, requestConfirmation, confirmAndStart, cancel, reset
    }

    /// The method is not allowed in this state.
    case notAllowed(Action, in: WriteState.Phase)
    /// The selected image does not fit on the selected drive, so it can't be confirmed.
    case driveTooSmall(DriveTooSmall)
}

extension WriteCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAllowed(let action, let phase):
            return "Can't \(action.rawValue) while \(phase.rawValue)."
        case .driveTooSmall(let problem):
            return problem.message
        }
    }
}
