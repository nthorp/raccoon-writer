import Foundation

/// The Full Disk Access list in System Settings. Files & Folders would be the narrower
/// setting, but it hides the Removable Volumes switch for most apps (T25).
enum PrivacySettingsLink {
    /// Nil only if the URL stops parsing; the failed screen then hides its button.
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
