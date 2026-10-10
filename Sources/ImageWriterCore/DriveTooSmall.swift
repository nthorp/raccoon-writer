import Foundation

/// The image doesn't fit on the drive. Checked from the listed size when both are
/// selected, so the user hears about it before the confirm screen; the write engine
/// still checks the opened device as a backstop.
public struct DriveTooSmall: Equatable, Sendable {
    public var imageBytes: UInt64
    public var driveBytes: UInt64

    public init(imageBytes: UInt64, driveBytes: UInt64) {
        self.imageBytes = imageBytes
        self.driveBytes = driveBytes
    }

    /// Nil when the image fits.
    public init?(image: ImageInfo, drive: DiskInfo) {
        guard image.sizeBytes > drive.sizeBytes else { return nil }
        self.init(imageBytes: image.sizeBytes, driveBytes: drive.sizeBytes)
    }

    public var message: String {
        "The image (\(DisplayFormat.size(imageBytes))) is larger than the drive (\(DisplayFormat.size(driveBytes))). Choose a drive of at least \(DisplayFormat.size(imageBytes))."
    }
}
