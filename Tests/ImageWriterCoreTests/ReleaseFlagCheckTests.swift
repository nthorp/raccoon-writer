import Foundation
import Testing
@testable import ImageWriterCore

/// `scripts/check-release-flags.sh` must pass a clean bundle and fail one that contains
/// any debug-only marker. Runs against fake bundles in a temp directory.
struct ReleaseFlagCheckTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/check-release-flags.sh")

    static let markers = ["ISOSWORD_ALLOW_VIRTUAL_DISKS", "DebugTestMode", "allowVirtualDisks"]

    /// A minimal `.app` whose executable holds `contents`. Removed by the caller.
    func makeBundle(executable contents: Data?, extraFile: (name: String, contents: Data)? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("isosword-flagcheck-\(UUID().uuidString)")
        let app = root.appendingPathComponent("IsoSword.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        if let contents {
            try contents.write(to: macOS.appendingPathComponent("IsoSword"))
        }
        if let extraFile {
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try extraFile.contents.write(to: frameworks.appendingPathComponent(extraFile.name))
        }
        return app
    }

    func run(on bundle: String) throws -> Int32 {
        let process = Process()
        process.executableURL = Self.script
        process.arguments = [bundle]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func binary(containing marker: String?) -> Data {
        var bytes = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x01])
        bytes.append(Data("__cstring\0Select Image\0".utf8))
        if let marker {
            bytes.append(Data("\(marker)\0".utf8))
        }
        bytes.append(Data([0x00, 0xFF, 0x7F]))
        return bytes
    }

    @Test func cleanBundlePasses() throws {
        let app = try makeBundle(executable: binary(containing: nil))
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(try run(on: app.path) == 0)
    }

    @Test(arguments: markers)
    func leakedMarkerInExecutableFails(_ marker: String) throws {
        let app = try makeBundle(executable: binary(containing: marker))
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(try run(on: app.path) == 1)
    }

    @Test func leakedMarkerInAnyBundleFileFails() throws {
        let app = try makeBundle(
            executable: binary(containing: nil),
            extraFile: ("ImageWriterCore", binary(containing: "ISOSWORD_ALLOW_VIRTUAL_DISKS"))
        )
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(try run(on: app.path) == 1)
    }

    @Test func missingOrEmptyBundleFailsClosed() throws {
        #expect(try run(on: "/nonexistent/isosword/IsoSword.app") == 2)
        let empty = try makeBundle(executable: nil)
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        #expect(try run(on: empty.path) == 2)
    }

    @Test func scriptChecksEveryMarkerTheCodeUses() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        for marker in Self.markers {
            #expect(text.contains("\n    \(marker)\n"))
        }
#if DEBUG
        #expect(Self.markers.contains(DebugTestMode.environmentKey))
        #expect(String(describing: DebugTestMode.self) == "DebugTestMode")
#endif
    }
}
