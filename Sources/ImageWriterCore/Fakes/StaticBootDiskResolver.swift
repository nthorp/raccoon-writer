#if DEBUG
import Foundation

/// A `BootDiskResolving` that always returns the same boot disks, for the debug
/// Simulate mode. Built from names; invalid names make every resolve fail, as a real
/// unresolvable boot disk does.
public struct StaticBootDiskResolver: BootDiskResolving {
    private let bootDisks: BootDiskSet?

    public init(wholeDisks: Set<String>) {
        bootDisks = BootDiskSet(wholeDisks)
    }

    public func resolveBootDisks() async throws -> BootDiskSet {
        guard let bootDisks else {
            throw DiskDiscoveryError.bootDiskUnresolved(reason: "StaticBootDiskResolver was given no valid whole-disk names")
        }
        return bootDisks
    }
}
#endif
