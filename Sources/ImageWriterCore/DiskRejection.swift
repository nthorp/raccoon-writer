import Foundation

/// Why `DiskFilter` will not offer a disk as a write target. Ordered from the
/// always-applied safety rules to the default-mode rules.
public enum DiskRejection: Equatable, Sendable {
    case invalidName
    case notWholeDisk
    case internalDisk
    case bootDisk
    /// A volume on it is mounted at `/` or under `/System/Volumes`.
    case systemVolume
    case apfsContainer
    case virtualDisk
    /// Size 0, e.g. a card reader with no card inserted.
    case noMedia
    /// Default mode only.
    case notUSB
    /// Default mode only.
    case notRemovable
}
