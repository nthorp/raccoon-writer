import Foundation

/// Validates a chosen image file and detects boot signatures from its first 64 KiB.
/// Never reads the rest of the file, so it is cheap even for multi-gigabyte images.
public struct ImageInspector: Sendable {
    public init() {}

    public func inspect(url: URL) throws -> ImageInfo {
        guard url.isFileURL else { throw ImageInspectorError.notAFileURL(url.absoluteString) }
        let fileName = url.lastPathComponent
        // Checked before touching the file, so an unsupported pick does no I/O.
        guard let kind = ImageKind(pathExtension: url.pathExtension) else {
            throw ImageInspectorError.unsupportedExtension(fileName: fileName)
        }

        // O_NONBLOCK so a FIFO cannot hang the open; fstat on the open descriptor
        // avoids a check-then-open race on the file type.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.openError(errno, fileName: fileName) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ImageInspectorError.posix(operation: "inspect", fileName: fileName, code: errno)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw ImageInspectorError.isDirectory(fileName: fileName)
        default: throw ImageInspectorError.notRegularFile(fileName: fileName)
        }
        guard info.st_size > 0 else { throw ImageInspectorError.empty(fileName: fileName) }

        let header = try Self.readHeader(fd: fd, fileName: fileName)
        let signatures = ImageSignatures(header: header)
        return ImageInfo(
            url: url,
            fileName: fileName,
            sizeBytes: UInt64(info.st_size),
            identity: FileIdentity(info),
            kind: kind,
            hasMBR: signatures.hasMBR,
            hasGPT: signatures.hasGPT,
            isISO9660: signatures.isISO9660,
            bootWarning: signatures.bootWarning
        )
    }

    /// Reads up to `ImageSignatures.headerLength` bytes from the start, fewer at end of file.
    static func readHeader(fd: Int32, fileName: String) throws -> [UInt8] {
        var header = [UInt8](repeating: 0, count: ImageSignatures.headerLength)
        var filled = 0
        try header.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < buffer.count {
                let count = pread(fd, base + filled, buffer.count - filled, off_t(filled))
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ImageInspectorError.posix(operation: "read", fileName: fileName, code: errno)
                }
                filled += count
            }
        }
        return Array(header.prefix(filled))
    }

    private static func openError(_ code: Int32, fileName: String) -> ImageInspectorError {
        switch code {
        case ENOENT, ENOTDIR: return .notFound(fileName: fileName)
        case EACCES, EPERM: return .permissionDenied(fileName: fileName)
        default: return .posix(operation: "open", fileName: fileName, code: code)
        }
    }
}
