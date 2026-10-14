import Foundation

/// The drive is bigger than USB sticks usually are, so it may be a backup or external
/// hard drive. The default list includes those because they report ejectable. Advisory
/// only, like `BootWarning`: it never blocks the write.
public struct LargeDriveWarning: Equatable, Sendable {
    /// Decimal, as `DisplayFormat` and Finder count, so a "500 GB" SSD that is a little
    /// over is still warned about. 128 and 256 GB sticks are common, so they stay below.
    public static let thresholdBytes: UInt64 = 500_000_000_000

    public var driveBytes: UInt64

    /// Nil at or below the threshold.
    public init?(drive: DiskInfo) {
        guard drive.sizeBytes > Self.thresholdBytes else { return nil }
        driveBytes = drive.sizeBytes
    }

    /// Names the drive's size rather than the threshold, so a 500.1 GB drive doesn't read
    /// "larger than 500 GB" next to "500 GB".
    public var message: String {
        "This is a large drive (\(DisplayFormat.size(driveBytes))). USB sticks are rarely this big, so make sure it isn’t a backup or external hard drive you want to keep."
    }
}
