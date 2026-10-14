import Foundation

/// Something the failed screen can offer besides Try Again. The app layer decides how
/// to carry it out, so the core stays UI-free.
public enum FailureAction: Equatable, Sendable {
    /// Open Privacy & Security › Full Disk Access in System Settings. Not Files &
    /// Folders: there, an app with a Full Disk Access entry (even a denied one, which
    /// macOS adds by itself) shows no Removable Volumes switch (T25).
    case openFullDiskAccessSettings
}
