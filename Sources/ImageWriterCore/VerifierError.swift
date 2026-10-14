import Foundation

/// Failures reading the image back from the drive. Image file problems are
/// `ImageSourceError`, and a cancelled verify throws `CancellationError`.
public enum VerifierError: Error, Equatable, Sendable {
    /// The drive is smaller than the image, so it cannot hold a full copy. Checked before reading.
    case imageTooLarge(imageBytes: UInt64, deviceBytes: UInt64)
    /// A read from the drive failed. `ENXIO` or `EIO` usually means it was removed.
    case read(DeviceIOError)
    /// The drive returned no data at `atOffset`, inside its reported size.
    case deviceEnded(atOffset: UInt64)
    /// The drive returned `byteCount` bytes at `atOffset`, which isn't a whole number of
    /// blocks. The rest can't be retried, because a raw device only reads whole blocks.
    case partialBlock(atOffset: UInt64, byteCount: Int)
    /// The drive differs from the image, first at image byte `atOffset`.
    case verificationFailed(atOffset: UInt64)
}

extension VerifierError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .imageTooLarge(let imageBytes, let deviceBytes):
            let image = ByteCountFormatter.string(fromByteCount: Int64(clamping: imageBytes), countStyle: .file)
            let device = ByteCountFormatter.string(fromByteCount: Int64(clamping: deviceBytes), countStyle: .file)
            return "The image (\(image)) is larger than the drive (\(device)), so it cannot be verified."
        case .read(let error):
            return "Reading back from the drive failed. \(error.localizedDescription)"
        case .deviceEnded(let offset):
            return "The drive stopped returning data at byte \(offset)."
        case .partialBlock(let offset, let count):
            return "The drive returned \(count) bytes at byte \(offset), which is not a whole number of blocks."
        case .verificationFailed(let offset):
            return "The data on the drive does not match the image, starting at byte \(offset)."
        }
    }
}
