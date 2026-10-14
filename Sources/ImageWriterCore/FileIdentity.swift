import Foundation

/// Which file the image is, and which version of it, as `stat` reports it. A file
/// replaced at the same path has a different inode, and one rewritten in place has a
/// different modification time, even when the size stays the same. `ctime` is left
/// out: Finder and Spotlight change it by adding extended attributes, which would
/// report an untouched image as changed.
public struct FileIdentity: Equatable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public var sizeBytes: Int64
    public var modifiedSeconds: Int
    public var modifiedNanoseconds: Int

    public init(device: Int32, inode: UInt64, sizeBytes: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int) {
        self.device = device
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    public init(_ info: stat) {
        self.init(
            device: info.st_dev,
            inode: info.st_ino,
            sizeBytes: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
