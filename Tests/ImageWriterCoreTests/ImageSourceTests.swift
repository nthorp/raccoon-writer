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

    /// The file's real identity, with `size` as the selected size.
    func info(_ url: URL, size: UInt64) throws -> ImageInfo {
        var info = try imageInfo(at: url)
        info.sizeBytes = size
        return info
    }

    func file(_ bytes: [UInt8], named name: String = "disk.img") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// Overwrites the start of the file in place, keeping its inode and size, and sets
    /// its modification time explicitly so the test doesn't depend on timestamp resolution.
    func rewriteInPlace(_ url: URL, modifiedSeconds: Int) throws {
        let fd = open(url.path, O_WRONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let bytes: [UInt8] = [1, 2, 3, 4]
        #expect(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == bytes.count)
        try setModified(fd, seconds: modifiedSeconds)
    }

    func setModified(_ fd: Int32, seconds: Int) throws {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        try #require(futimes(fd, &times) == 0)
    }

    func setModified(_ url: URL, seconds: Int) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try setModified(fd, seconds: seconds)
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
            _ = try ImageSource(image: try self.info(url, size: 64))
        }
    }

    @Test func missingFile() {
        let url = dir.appendingPathComponent("gone.img")
        let info = ImageInfo(
            url: url, fileName: "gone.img", sizeBytes: 1, identity: .madeUp, kind: .img,
            hasMBR: false, hasGPT: false, isISO9660: false, bootWarning: nil
        )
        #expect(throws: ImageSourceError.posix(operation: "open", fileName: "gone.img", code: ENOENT)) {
            _ = try ImageSource(image: info)
        }
    }

    // MARK: - Identity

    @Test func untouchedFilePassesBothChecks() throws {
        let url = try file(pattern(count: 4_096))
        let source = try ImageSource(image: imageInfo(at: url))
        _ = try read(source, count: 4_096, at: 0)
        try source.checkUnchanged()
    }

    @Test func sameSizeFileRenamedOverThePathIsAChange() throws {
        let url = try file(pattern(count: 4_096))
        try setModified(url, seconds: 1_000_000_000)
        let selected = try imageInfo(at: url)
        // Same size and modification time; only the inode differs.
        let other = try file(pattern(count: 4_096, seed: 0x5A), named: "other.img")
        try setModified(other, seconds: 1_000_000_000)
        #expect(rename(other.path, url.path) == 0)
        #expect(throws: ImageSourceError.changed(fileName: "disk.img")) {
            _ = try ImageSource(image: selected)
        }
    }

    @Test func fileRewrittenInPlaceBeforeOpeningIsAChange() throws {
        let url = try file(pattern(count: 4_096))
        try setModified(url, seconds: 1_000_000_000)
        let selected = try imageInfo(at: url)
        try rewriteInPlace(url, modifiedSeconds: 1_000_000_001)
        #expect(try fileIdentity(at: url).inode == selected.identity.inode)
        #expect(throws: ImageSourceError.changed(fileName: "disk.img")) {
            _ = try ImageSource(image: selected)
        }
    }

    @Test func fileRewrittenInPlaceWhileOpenFailsTheCheck() throws {
        let url = try file(pattern(count: 4_096))
        try setModified(url, seconds: 1_000_000_000)
        let source = try ImageSource(image: imageInfo(at: url))
        try rewriteInPlace(url, modifiedSeconds: 1_000_000_001)
        #expect(throws: ImageSourceError.changed(fileName: "disk.img")) {
            try source.checkUnchanged()
        }
    }
}
