import Foundation

/// Decides which disks may be shown as write targets.
///
/// Default: external, removable or ejectable, physical USB whole disks.
/// `showAllExternal`: any external physical whole disk.
/// Under both settings, the boot disks, internal disks, APFS containers and disks
/// with system volumes mounted are never shown.
public struct DiskFilter: Sendable {
    public var showAllExternal: Bool

    public init(showAllExternal: Bool = false) {
        self.showAllExternal = showAllExternal
    }

    public func targets(from disks: [DiskInfo], bootDisks: BootDiskSet) -> [DiskInfo] {
        disks.filter { rejection(for: $0, bootDisks: bootDisks) == nil }
    }

    /// Nil if `disk` may be offered as a target, otherwise the first rule it breaks.
    public func rejection(for disk: DiskInfo, bootDisks: BootDiskSet) -> DiskRejection? {
        guard BSDName.isWholeDisk(disk.bsdName) else { return .invalidName }
        guard disk.isWholeDisk else { return .notWholeDisk }
        guard !disk.isInternal else { return .internalDisk }
        guard !bootDisks.contains(disk.bsdName) else { return .bootDisk }
        guard !disk.mountPoints.contains(where: Self.isSystemMountPoint) else { return .systemVolume }
        guard !disk.isAPFSContainer else { return .apfsContainer }
        guard !disk.isVirtual else { return .virtualDisk }
        guard disk.sizeBytes > 0 else { return .noMedia }
        if !showAllExternal {
            guard disk.busProtocol == "USB" else { return .notUSB }
            guard disk.isRemovable || disk.isEjectable else { return .notRemovable }
        }
        return nil
    }

    // A second line of defense behind boot-disk resolution.
    static func isSystemMountPoint(_ path: String) -> Bool {
        path == "/" || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/")
    }
}
