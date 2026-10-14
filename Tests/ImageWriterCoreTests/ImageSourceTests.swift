import Foundation
import Testing
@testable import ImageWriterCore

/// Each test gets its own temp directory, removed in `deinit`.
final class ImageSourceTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func info(_ url: URL, size: UInt64) -> ImageInfo {
        ImageInfo(
            url: url, fileName: url.lastPathComponent, sizeBytes: size, kind: .img,
            hasMBR: false, hasGPT: false, isISO9660: false, bootWarning: nil
        )
    }

    func file(_ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent("disk.img")
        try Data(bytes).write(to: url)
        return url
    }

    func read(_ source: ImageSource, count: Int, at offset: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { try source.readFully(into: $0, at: offset) }
        return bytes
    }

    @Test func readsAtOffsets() throws {
        let bytes = pattern(count: 10_000)
        let source = try ImageSource(image: info(file(bytes), size: 10_000))
        #expect(try read(source, count: 1_000, at: 0) == Array(bytes[..<1_000]))
        #expect(try read(source, count: 1_234, at: 8_766) == Array(bytes[8_766...]))
    }

    @Test func readingPastTheEndIsTruncation() throws {
        let source = try ImageSource(image: info(file(pattern(count: 1_000)), size: 1_000))
        #expect(throws: ImageSourceError.truncated(fileName: "disk.img", atOffset: 1_000)) {
            _ = try self.read(source, count: 100, at: 950)
        }
    }

    @Test func fileTruncatedAfterOpening() throws {
        let url = try file(pattern(count: 4_096))
        let source = try ImageSource(image: info(url, size: 4_096))
        #expect(truncate(url.path, 2_048) == 0)
        #expect(throws: ImageSourceError.truncated(fileName: "disk.img", atOffset: 2_048)) {
            _ = try self.read(source, count: 4_096, at: 0)
        }
    }

    @Test(arguments: [UInt64(999), 1_001])
    func sizeDifferentFromSelectionIsAChange(_ size: UInt64) throws {
        let url = try file(pattern(count: 1_000))
        #expect(throws: ImageSourceError.changed(fileName: "disk.img")) {
            _ = try ImageSource(image: self.info(url, size: size))
        }
    }

    @Test func directoryIsAChange() throws {
        let url = dir.appendingPathComponent("folder.img")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: ImageSourceError.changed(fileName: "folder.img")) {
            _ = try ImageSource(image: self.info(url, size: 64))
        }
    }

    @Test func missingFile() {
        let url = dir.appendingPathComponent("gone.img")
        #expect(throws: ImageSourceError.posix(operation: "open", fileName: "gone.img", code: ENOENT)) {
            _ = try ImageSource(image: self.info(url, size: 1))
        }
    }
}
