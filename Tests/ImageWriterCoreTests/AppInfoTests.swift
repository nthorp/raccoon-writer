import Testing
@testable import ImageWriterCore

struct AppInfoTests {
    @Test func displayName() {
        #expect(AppInfo.displayName == "Red Delicious Media Writer")
    }

    @Test func shortName() {
        #expect(AppInfo.shortName == "Red Delicious")
    }

    /// macOS truncates a longer `CFBundleName` in the menu bar.
    @Test func shortNameFitsBundleName() {
        #expect(AppInfo.shortName.count <= 15)
    }
}
