import Foundation

/// A `DiskDiscovery` that always lists the same disks, for the debug Simulate mode.
public struct StaticDiskDiscovery: DiskDiscovery {
    public var disks: [DiskInfo]

    public init(disks: [DiskInfo]) {
        self.disks = disks
    }

    public func listDisks() async throws -> [DiskInfo] { disks }
}
