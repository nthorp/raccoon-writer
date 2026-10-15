import Foundation

/// Why `DiskFilter` will not offer a disk as a write target. Ordered from the
/// always-applied safety rules to the default-mode rules.
public enum DiskRejection: Equatable, Sendable {
    case invalidName
    case notWholeDisk
    /// Any internal disk except a built-in SD card reader.
    case internalDisk
    case bootDisk
    /// A volume on it is mounted at `/` or under `/System/Volumes`.
    case systemVolume
    case apfsContainer
    case virtualDisk
    /// Size 0, e.g. a card reader with no card inserted.
    case noMedia
    /// Default mode only. A built-in SD card reader is exempt.
    case notUSB
    /// Default mode only.
    case notRemovable
}

extension DiskRejection {
    /// One sentence for the user, ending with a period.
    public var explanation: String {
        switch self {
        case .invalidName: return "its name is not a whole-disk name."
        case .notWholeDisk: return "it is a partition, not a whole disk."
        case .internalDisk: return "it is an internal disk."
        case .bootDisk: return "macOS is running from it."
        case .systemVolume: return "a macOS system volume is mounted from it."
        case .apfsContainer: return "it is an APFS container, not a physical disk."
        case .virtualDisk: return "it is a disk image."
        case .noMedia: return "it has no media inserted."
        case .notUSB: return "it is not a USB drive. Turn on \"Show all external disks\" to use it."
        case .notRemovable: return "it is not a removable drive. Turn on \"Show all external disks\" to use it."
        }
    }
}
