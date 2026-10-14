import Foundation

/// Read access to the selected image, checked against the `FileIdentity` that
/// `ImageInspector` recorded. A file replaced at the same path, or changed in place
/// since it was selected, fails at init; one changed in place while open fails
/// `checkUnchanged()`. A file truncated while open fails the read that runs out.
final class ImageSource {
    let fileName: String
    let sizeBytes: UInt64
    private let identity: FileIdentity
    private let fd: Int32

    init(image: ImageInfo) throws {
        fileName = image.fileName
        sizeBytes = image.sizeBytes
        identity = image.identity
        // O_NONBLOCK so a FIFO swapped in at the same path cannot hang the open.
        let fd = open(image.url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw ImageSourceError.posix(operation: "open", fileName: image.fileName, code: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw ImageSourceError.posix(operation: "open", fileName: image.fileName, code: code)
        }
        // The size is compared too, because `sizeBytes` is what gets copied and must
        // agree with the identity's size even if the two were built separately.
        guard info.st_mode & S_IFMT == S_IFREG,
              FileIdentity(info) == image.identity,
              UInt64(exactly: info.st_size) == image.sizeBytes else {
            close(fd)
            throw ImageSourceError.changed(fileName: image.fileName)
        }
        self.fd = fd
    }

    deinit { close(fd) }

    /// Throws `changed` if the open file was modified since it was selected, so a
    /// change during the run can't end in a drive reported as verified.
    func checkUnchanged() throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw ImageSourceError.posix(operation: "check", fileName: fileName, code: errno)
        }
        guard FileIdentity(info) == identity else {
            throw ImageSourceError.changed(fileName: fileName)
        }
    }

    /// Fills `buffer` from `offset`. Running out of file is an error, not end of input,
    /// because the image's length was fixed when it was selected.
    func readFully(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws {
        var filled = 0
        while filled < buffer.count {
            let position = offset + UInt64(filled)
            let count: Int
            do {
                count = try PosixIO.pread(fd, into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]), at: position)
            } catch DeviceIOError.posix(_, let code) {
                throw ImageSourceError.posix(operation: "read", fileName: fileName, code: code)
            }
            guard count > 0 else { throw ImageSourceError.truncated(fileName: fileName, atOffset: position) }
            filled += count
        }
    }
}
