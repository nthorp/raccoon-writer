import Foundation

/// A coordinator method was called in a state where it is not allowed. Nothing changed.
public enum WriteCoordinatorError: Error, Equatable, Sendable {
    public enum Action: String, Sendable {
        case selectImage, selectDrive, requestConfirmation, confirmAndStart, cancel, reset
    }

    case notAllowed(Action, in: WriteState.Phase)
}

extension WriteCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAllowed(let action, let phase):
            return "Can't \(action.rawValue) while \(phase.rawValue)."
        }
    }
}
