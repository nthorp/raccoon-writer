import Foundation

/// Determines which whole disks back the running system. Must throw rather than
/// return a partial answer.
public protocol BootDiskResolving: Sendable {
    func resolveBootDisks() async throws -> BootDiskSet
}

/// Resolves the boot disks with `diskutil info -plist /`. On APFS, `/` lives on a
/// synthesized container (`disk3`), so each `APFSPhysicalStores` partition is also
/// resolved to its physical whole disk (`disk0`).
public struct BootDiskResolver: BootDiskResolving {
    private let diskutil: Diskutil

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        diskutil = Diskutil(runner: runner)
    }

    public func resolveBootDisks() async throws -> BootDiskSet {
        let root = try await diskutil.info("/")
        var disks: Set<String> = [try wholeDisk(of: root, describing: "/")]

        let stores = root.apfsPhysicalStores ?? []
        let isAPFS = root.filesystemType == "apfs" || root.apfsContainerReference != nil
        if isAPFS && stores.isEmpty {
            throw DiskDiscoveryError.bootDiskUnresolved(reason: "the APFS boot volume lists no physical store")
        }
        for store in stores {
            let info = try await diskutil.info(store.identifier)
            disks.insert(try wholeDisk(of: info, describing: store.identifier))
        }

        guard let set = BootDiskSet(disks) else {
            throw DiskDiscoveryError.bootDiskUnresolved(reason: "no boot disk found")
        }
        return set
    }

    private func wholeDisk(of info: DiskutilInfo, describing target: String) throws -> String {
        guard let parent = info.parentWholeDisk, BSDName.isWholeDisk(parent) else {
            throw DiskDiscoveryError.bootDiskUnresolved(reason: "diskutil reported no whole disk for \(target)")
        }
        return parent
    }
}
