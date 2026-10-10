import Foundation

/// The list the drive picker shows: discovery, boot-disk resolution and filtering in one
/// call. Fails closed: if the boot disk can't be resolved it throws, never returning an
/// unfiltered list.
public struct TargetDiskLister: Sendable {
    private let discovery: any DiskDiscovery
    private let bootResolver: any BootDiskResolving

    public init(discovery: any DiskDiscovery, bootResolver: any BootDiskResolving) {
        self.discovery = discovery
        self.bootResolver = bootResolver
    }

    /// Production wiring through diskutil.
    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.init(discovery: DiskutilDiscovery(runner: runner), bootResolver: BootDiskResolver(runner: runner))
    }

    /// Uses `DiskFilter.configured`, so Debug builds honor the virtual-disk test mode.
    public func targets(showAllExternal: Bool) async throws -> [DiskInfo] {
        try await targets(filter: .configured(showAllExternal: showAllExternal))
    }

    /// Pass the same `filter` to `SafetyGuard.validate` for the disk the user picks.
    public func targets(filter: DiskFilter) async throws -> [DiskInfo] {
        let bootDisks = try await bootResolver.resolveBootDisks()
        let disks = try await discovery.listDisks()
        return filter.targets(from: disks, bootDisks: bootDisks)
    }
}
