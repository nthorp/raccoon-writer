import Foundation

/// The image file is stored on the drive chosen as its target. The write starts by
/// unmounting the drive, so the file would be gone before a byte was copied, and the
/// write would erase it anyway. Checked when both are selected, like `DriveTooSmall`,
/// and again by `SafetyGuard` against the drive's mount points just before the unmount.
public struct ImageOnDrive: Equatable, Sendable {
    public var fileName: String
    /// The drive's volume the image is on.
    public var mountPoint: String

    public init(fileName: String, mountPoint: String) {
        self.fileName = fileName
        self.mountPoint = mountPoint
    }

    /// Nil when the image is not on any of the drive's volumes. `DiskInfo.mountPoints`
    /// includes the volumes of an APFS container stored on the drive.
    public init?(image: ImageInfo, drive: DiskInfo) {
        guard drive.mountPoints.contains(image.volumeMountPoint) else { return nil }
        self.init(fileName: image.fileName, mountPoint: image.volumeMountPoint)
    }

    public var message: String {
        "“\(fileName)” is stored on this drive (\(mountPoint)), and writing erases the whole drive. Copy the image to your Mac, choose the copy, then try again."
    }
}
