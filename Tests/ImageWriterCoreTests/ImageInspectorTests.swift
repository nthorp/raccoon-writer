import Foundation
import Testing
@testable import ImageWriterCore

/// Each test gets its own temp directory, removed in `deinit`.
final class ImageInspectorTests {
    let dir: URL
    let inspector = ImageInspector()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Synthetic image bytes with the requested signatures placed where they fit.
    func image(size: Int, mbr: Bool = false, gpt: Bool = false, iso: Bool = false) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        func place(_ signature: [UInt8], at offset: Int) {
            for (i, byte) in signature.enumerated() where offset + i < size { bytes[offset + i] = byte }
        }
        if mbr { place([0x55, 0xAA], at: 510) }
        if gpt { place(Array("EFI PART".utf8), at: 512) }
        if iso { place([0x01] + Array("CD001".utf8), at: 0x8000) }
        return bytes
    }

    func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Signatures and warning

    @Test func hybridISO() throws {
        let url = try file("distro.iso", image(size: 1 << 20, mbr: true, gpt: true, iso: true))
        let info = try inspector.inspect(url: url)
        #expect(info == ImageInfo(
            url: url, fileName: "distro.iso", sizeBytes: 1 << 20, identity: try fileIdentity(at: url),
            volumeMountPoint: try volumeMountPoint(at: url), kind: .iso,
            hasMBR: true, hasGPT: true, isISO9660: true, bootWarning: nil
        ))
    }

    @Test func recordsTheMountPointOfTheFilesVolume() throws {
        let url = try file("disk.img", image(size: 4096, mbr: true))
        let info = try inspector.inspect(url: url)
        var volume = statfs()
        #expect(statfs(url.deletingLastPathComponent().path, &volume) == 0)
        #expect(!info.volumeMountPoint.isEmpty)
        #expect(info.volumeMountPoint == ImageInspector.mountPoint(of: volume))
    }

    @Test func mountPointIsReadUpToItsTerminator() {
        var root = statfs()
        #expect(statfs("/", &root) == 0)
        #expect(ImageInspector.mountPoint(of: root) == "/")
    }

    @Test func isoOnlyGetsWarning() throws {
        let info = try inspector.inspect(url: file("dvd.iso", image(size: 1 << 20, iso: true)))
        #expect(info.isISO9660)
        #expect(!info.hasMBR && !info.hasGPT)
        #expect(info.bootWarning == .mayNotBootFromUSB)
    }

    @Test(arguments: [(true, false), (false, true)])
    func isoWithEitherPartitionTableHasNoWarning(mbr: Bool, gpt: Bool) throws {
        let info = try inspector.inspect(url: file("hybrid.iso", image(size: 1 << 20, mbr: mbr, gpt: gpt, iso: true)))
        #expect(info.hasMBR == mbr && info.hasGPT == gpt)
        #expect(info.bootWarning == nil)
    }

    @Test func imgWithMBR() throws {
        let info = try inspector.inspect(url: file("raspios.img", image(size: 300_000, mbr: true)))
        #expect(info.kind == .img)
        #expect(info.hasMBR && !info.hasGPT && !info.isISO9660)
        #expect(info.sizeBytes == 300_000)
        #expect(info.bootWarning == nil)
    }

    @Test func imgWithGPT() throws {
        // Real GPT disks also carry a protective MBR.
        let info = try inspector.inspect(url: file("disk.img", image(size: 1 << 20, mbr: true, gpt: true)))
        #expect(info.kind == .img)
        #expect(info.hasMBR && info.hasGPT && !info.isISO9660)
        #expect(info.bootWarning == nil)
    }

    @Test func imgWithoutSignaturesHasNoWarning() throws {
        let info = try inspector.inspect(url: file("blank.img", image(size: 1 << 20)))
        #expect(!info.hasMBR && !info.hasGPT && !info.isISO9660)
        #expect(info.bootWarning == nil)
    }

    @Test func warningFollowsContentNotExtension() throws {
        let info = try inspector.inspect(url: file("renamed.img", image(size: 1 << 20, iso: true)))
        #expect(info.kind == .img)
        #expect(info.bootWarning == .mayNotBootFromUSB)
    }

    @Test func signaturesAtWrongOffsetsAreIgnored() throws {
        var bytes = image(size: 1 << 20)
        bytes[510] = 0xAA; bytes[511] = 0x55
        bytes.replaceSubrange(513 ..< 521, with: Array("EFI PART".utf8))
        bytes.replaceSubrange(0x8000 ..< 0x8005, with: Array("CD001".utf8))
        let info = try inspector.inspect(url: file("shifted.img", bytes))
        #expect(!info.hasMBR && !info.hasGPT && !info.isISO9660)
    }

    @Test(arguments: ["UPPER.ISO", "Mixed.Iso", "photo.IMG"])
    func extensionIsCaseInsensitive(_ name: String) throws {
        let info = try inspector.inspect(url: file(name, image(size: 4096)))
        #expect(info.kind == ImageKind(rawValue: (name as NSString).pathExtension.lowercased()))
    }

    // MARK: - Short files

    @Test func shortFileDetectsWhatFits() throws {
        let info = try inspector.inspect(url: file("tiny.img", image(size: 600, mbr: true, gpt: true)))
        #expect(info.sizeBytes == 600)
        #expect(info.hasMBR && info.hasGPT && !info.isISO9660)
    }

    @Test func isoSignatureNeedsAllFiveBytes() throws {
        let truncated = try inspector.inspect(url: file("cut.iso", image(size: 0x8005, iso: true)))
        #expect(!truncated.isISO9660)
        #expect(truncated.bootWarning == nil)
        let exact = try inspector.inspect(url: file("exact.iso", image(size: 0x8006, iso: true)))
        #expect(exact.isISO9660)
        #expect(exact.bootWarning == .mayNotBootFromUSB)
    }

    @Test func fileShorterThanMBR() throws {
        let info = try inspector.inspect(url: file("stub.img", [UInt8](repeating: 0x55, count: 100)))
        #expect(info.sizeBytes == 100)
        #expect(!info.hasMBR && !info.hasGPT && !info.isISO9660)
    }

    // MARK: - Does not read the whole file

    @Test func readsOnlyTheHeader() throws {
        let url = try file("big.img", image(size: 1 << 20))
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(try ImageInspector.readHeader(fd: fd, fileName: "big.img").count == 64 * 1024)
    }

    @Test func hugeSparseFileIsInspectedQuickly() throws {
        // 1 TiB of holes: reading it all would take minutes, so returning at all
        // shows only the header was read.
        let url = try file("huge.iso", image(size: 64 * 1024, mbr: true, iso: true))
        let terabyte: off_t = 1 << 40
        try #require(truncate(url.path, terabyte) == 0)
        let start = ContinuousClock.now
        let info = try inspector.inspect(url: url)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(info.sizeBytes == UInt64(terabyte))
        #expect(info.hasMBR && info.isISO9660)
    }

    // MARK: - Rejections

    @Test(arguments: ["image.dmg", "image.iso.xz", "image.zip", "image", "iso", ".iso"])
    func rejectsWrongExtensionWithoutTouchingTheFile(_ name: String) {
        // The file does not exist, so getting unsupportedExtension (not notFound) shows no I/O happened.
        let url = dir.appendingPathComponent(name)
        #expect(throws: ImageInspectorError.unsupportedExtension(fileName: name)) {
            try self.inspector.inspect(url: url)
        }
    }

    @Test func rejectsEmptyFile() throws {
        let url = try file("empty.iso", [])
        #expect(throws: ImageInspectorError.empty(fileName: "empty.iso")) { try self.inspector.inspect(url: url) }
    }

    @Test func rejectsMissingFile() {
        let missing = dir.appendingPathComponent("gone.iso")
        #expect(throws: ImageInspectorError.notFound(fileName: "gone.iso")) { try self.inspector.inspect(url: missing) }
        let missingParent = dir.appendingPathComponent("nowhere/gone.img")
        #expect(throws: ImageInspectorError.notFound(fileName: "gone.img")) {
            try self.inspector.inspect(url: missingParent)
        }
    }

    @Test func rejectsDirectory() throws {
        let url = dir.appendingPathComponent("folder.iso", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: ImageInspectorError.isDirectory(fileName: "folder.iso")) { try self.inspector.inspect(url: url) }
    }

    @Test func rejectsUnreadableFile() throws {
        let url = try file("locked.img", image(size: 4096, mbr: true))
        try #require(chmod(url.path, 0) == 0)
        #expect(throws: ImageInspectorError.permissionDenied(fileName: "locked.img")) {
            try self.inspector.inspect(url: url)
        }
    }

    @Test func rejectsFIFOWithoutBlocking() throws {
        let url = dir.appendingPathComponent("pipe.iso")
        try #require(mkfifo(url.path, 0o600) == 0)
        #expect(throws: ImageInspectorError.notRegularFile(fileName: "pipe.iso")) { try self.inspector.inspect(url: url) }
    }

    @Test func rejectsNonFileURL() throws {
        let url = try #require(URL(string: "https://example.com/distro.iso"))
        #expect(throws: ImageInspectorError.notAFileURL("https://example.com/distro.iso")) {
            try self.inspector.inspect(url: url)
        }
    }

    @Test func followsSymlinks() throws {
        let target = try file("real.iso", image(size: 1 << 20, mbr: true, iso: true))
        let link = dir.appendingPathComponent("link.iso")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let info = try inspector.inspect(url: link)
        #expect(info.fileName == "link.iso")
        #expect(info.sizeBytes == 1 << 20)
        #expect(info.hasMBR && info.isISO9660)
    }

    @Test func errorsHaveDescriptions() {
        let errors: [ImageInspectorError] = [
            .notAFileURL("https://x"), .unsupportedExtension(fileName: "a.dmg"), .notFound(fileName: "a.iso"),
            .isDirectory(fileName: "a.iso"), .notRegularFile(fileName: "a.iso"),
            .permissionDenied(fileName: "a.iso"), .empty(fileName: "a.iso"),
            .posix(operation: "read", fileName: "a.iso", code: EIO),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(BootWarning.mayNotBootFromUSB.message.contains("may not boot"))
    }
}
