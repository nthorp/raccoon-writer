import Foundation

/// Something the failed screen can offer besides Try Again. The app layer decides how
/// to carry it out, so the core stays UI-free.
public enum FailureAction: Equatable, Sendable {
    /// Open Privacy & Security › Files & Folders in System Settings.
    case openPrivacySettings
}
