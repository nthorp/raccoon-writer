import Foundation

/// Something the confirm screen should mention after a run ended without a failure
/// screen. Cleared by the next state change.
public enum WriteNotice: Equatable, Sendable {
    /// The admin password dialog was dismissed. The drive's volumes were unmounted
    /// before it appeared, and stay that way until the drive is reinserted.
    case passwordPromptCancelled

    public var message: String {
        switch self {
        case .passwordPromptCancelled:
            return "The password dialog was cancelled, so nothing was written. The drive’s volumes have been unmounted; reinsert the drive to get them back."
        }
    }
}
