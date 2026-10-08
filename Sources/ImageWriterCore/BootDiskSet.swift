import Foundation

/// The whole disks that back the running system: the disk holding `/` and, on APFS,
/// the physical disks of its container. Never empty, so a `DiskFilter` can only run
/// after the boot disk was actually resolved.
public struct BootDiskSet: Hashable, Sendable {
    public let wholeDisks: Set<String>

    /// Nil if `wholeDisks` is empty or holds anything but whole-disk names.
    public init?(_ wholeDisks: Set<String>) {
        guard !wholeDisks.isEmpty, wholeDisks.allSatisfy(BSDName.isWholeDisk) else { return nil }
        self.wholeDisks = wholeDisks
    }

    public func contains(_ bsdName: String) -> Bool {
        wholeDisks.contains(bsdName)
    }
}
