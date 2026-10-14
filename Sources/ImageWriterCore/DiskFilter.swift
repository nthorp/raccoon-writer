import Foundation

/// Decides which disks may be shown as write targets.
///
/// Default: external, removable or ejectable, physical USB whole disks.
/// `showAllExternal`: any external physical whole disk.
/// Under both settings, the boot disks, internal disks, APFS containers and disks
/// with system volumes mounted are never shown.
public struct DiskFilter: Sendable {
    public var showAllExternal: Bool

#if DEBUG
    /// Debug builds only: also accept disk images with nothing mounted, under either
    /// setting. Every other rule still applies.
    public var allowVirtualDisks: Bool

    public init(showAllExternal: Bool = false, allowVirtualDisks: Bool = false) {
        self.showAllExternal = showAllExternal
        self.allowVirtualDisks = allowVirtualDisks
    }
#else
    public init(showAllExternal: Bool = false) {
        self.showAllExternal = showAllExternal
    }
#endif

    /// The filter the app should use: in Debug builds it honors
    /// `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1` (see `DebugTestMode`); in Release builds it is
    /// the plain filter.
    public static func configured(showAllExternal: Bool) -> DiskFilter {
#if DEBUG
        DiskFilter(showAllExternal: showAllExternal, allowVirtualDisks: DebugTestMode.allowsVirtualDisks())
#else
        DiskFilter(showAllExternal: showAllExternal)
#endif
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
        guard !disk.isVirtual || acceptsVirtual(disk) else { return .virtualDisk }
        guard disk.sizeBytes > 0 else { return .noMedia }
        // A disk image is never on the USB bus, so the default-mode rules would hide it.
        if !showAllExternal && !disk.isVirtual {
            guard disk.busProtocol == "USB" else { return .notUSB }
            guard disk.isRemovable || disk.isEjectable else { return .notRemovable }
        }
        return nil
    }

    private func acceptsVirtual(_ disk: DiskInfo) -> Bool {
#if DEBUG
        // A mounted image is probably in use (an Xcode or simulator runtime image, say).
        // Test disks are attached with -nomount.
        allowVirtualDisks && disk.mountPoints.isEmpty
#else
        false
#endif
    }

    // A second line of defense behind boot-disk resolution.
    static func isSystemMountPoint(_ path: String) -> Bool {
        path == "/" || path == "/System/Volumes" || path.hasPrefix("/System/Volumes/")
    }
}
