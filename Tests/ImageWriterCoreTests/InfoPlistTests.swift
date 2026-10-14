import Foundation
import Testing

/// `App/Info.plist` in the source tree carries the keys the About window, Finder and the
/// removable-volume privacy prompt read. The built copy is checked by hand with `plutil`.
struct InfoPlistTests {
    static let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Info.plist")

    func entries() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test(arguments: [
        "NSHumanReadableCopyright",
        "LSApplicationCategoryType",
        "NSRemovableVolumesUsageDescription",
    ])
    func keyIsPresentAndNotEmpty(_ key: String) throws {
        let value = try entries()[key] as? String
        #expect(value?.trimmingCharacters(in: .whitespaces).isEmpty == false)
    }

    @Test func categoryIsUtilities() throws {
        #expect(try entries()["LSApplicationCategoryType"] as? String == "public.app-category.utilities")
    }
}
