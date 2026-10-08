import Foundation

/// Lists every whole disk on the system, unfiltered. Use `TargetDiskLister` to get the
/// disks that may be shown as write targets.
public protocol DiskDiscovery: Sendable {
    func listDisks() async throws -> [DiskInfo]
}
