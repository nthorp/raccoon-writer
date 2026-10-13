import Foundation

/// Something the confirm screen should mention after a run ended without a failure
/// screen. Cleared by the next state change.
public enum WriteNotice: Equatable, Sendable {
    /// The admin password dialog was dismissed. It comes before the unmount, so the
    /// drive is as it was.
    case passwordPromptCancelled

    public var message: String {
        switch self {
        case .passwordPromptCancelled:
            return "The password dialog was cancelled, so nothing was written and the drive was left as it was."
        }
    }
}
