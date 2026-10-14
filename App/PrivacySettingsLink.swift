import Foundation

/// Where System Settings shows the Removable Volumes switch.
enum PrivacySettingsLink {
    /// Nil only if the URL stops parsing; the failed screen then hides its button.
    static let filesAndFolders = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
}
