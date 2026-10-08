import Testing
@testable import ImageWriterCore

struct AppInfoTests {
    @Test func displayName() {
        #expect(AppInfo.displayName == "ISO Sword")
    }
}
