import Foundation

/// Static identity shared by the app and the core library.
public enum AppInfo {
    /// Finder, Dock and window title.
    public static let displayName = "Red Delicious Media Writer"
    /// Menu bar (`CFBundleName`, at most 15 characters) and in sentences.
    public static let shortName = "Red Delicious"
    public static let bundleIdentifier = "com.example.reddelicious"
}
