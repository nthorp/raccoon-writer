import Foundation

/// Static identity shared by the app and the core library.
public enum AppInfo {
    /// Finder, Dock and window title.
    public static let displayName = "Raccoon Writer"
    /// Menu bar (`CFBundleName`, at most 15 characters) and in sentences. Equal to
    /// `displayName` today; kept separate so a longer full name only changes this file.
    public static let shortName = "Raccoon Writer"
    public static let bundleIdentifier = "com.raccoonwriter.app"
}
