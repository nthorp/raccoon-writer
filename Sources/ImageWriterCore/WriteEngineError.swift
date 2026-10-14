import Foundation

/// Failures writing the image to the drive. Image file problems are `ImageSourceError`,
/// and a cancelled write throws `CancellationError`.
public enum WriteEngineError: Error, Equatable, Sendable {
    /// Checked before anything is written.
    case imageTooLarge(imageBytes: UInt64, deviceBytes: UInt64)
    /// A write to the drive failed. `ENXIO` or `EIO` usually means it was removed.
    case write(DeviceIOError)
    /// The drive accepted no bytes at `atOffset`; retrying would never finish.
    case stalled(atOffset: UInt64)
    /// The drive wrote `byteCount` bytes at `atOffset`, which isn't a whole number of
    /// blocks. The rest can't be retried, because a raw device only takes whole blocks.
    case partialBlock(atOffset: UInt64, byteCount: Int)
    /// Flushing the drive after the last write failed.
    case sync(DeviceIOError)
}

extension WriteEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageTooLarge(let imageBytes, let deviceBytes):
            let image = ByteCountFormatter.string(fromByteCount: Int64(clamping: imageBytes), countStyle: .file)
            let device = ByteCountFormatter.string(fromByteCount: Int64(clamping: deviceBytes), countStyle: .file)
            return "The image (\(image)) is larger than the drive (\(device))."
        case .write(let error):
            return "Writing to the drive failed. \(error.localizedDescription)"
        case .stalled(let offset):
            return "The drive stopped accepting data at byte \(offset)."
        case .partialBlock(let offset, let count):
            return "The drive wrote \(count) bytes at byte \(offset), which is not a whole number of blocks."
        case .sync(let error):
            return "Flushing data to the drive failed. \(error.localizedDescription)"
        }
    }
}
