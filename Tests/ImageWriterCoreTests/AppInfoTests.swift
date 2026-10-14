import Testing
@testable import ImageWriterCore

struct AppInfoTests {
    @Test func displayName() {
        #expect(AppInfo.displayName == "Raccoon Writer")
    }

    @Test func shortName() {
        #expect(AppInfo.shortName == "Raccoon Writer")
    }

    /// macOS truncates a longer `CFBundleName` in the menu bar.
    @Test func shortNameFitsBundleName() {
        #expect(AppInfo.shortName.count <= 15)
    }
}
