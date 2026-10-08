import Foundation

/// The subset of `diskutil list -plist` we read: the whole-disk names and the volume
/// tree used to attribute mount points to whole disks.
struct DiskutilList: Decodable, Sendable {
    var wholeDisks: [String]
    var entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case wholeDisks = "WholeDisks"
        case entries = "AllDisksAndPartitions"
    }

    /// A whole disk with its partitions, or an APFS container with its volumes.
    struct Entry: Decodable, Sendable {
        var deviceIdentifier: String
        var mountPoint: String?
        var volumeName: String?
        var partitions: [Volume]?
        var apfsVolumes: [Volume]?
        var apfsPhysicalStores: [StoreReference]?

        enum CodingKeys: String, CodingKey {
            case deviceIdentifier = "DeviceIdentifier"
            case mountPoint = "MountPoint"
            case volumeName = "VolumeName"
            case partitions = "Partitions"
            case apfsVolumes = "APFSVolumes"
            case apfsPhysicalStores = "APFSPhysicalStores"
        }
    }

    struct Volume: Decodable, Sendable {
        var deviceIdentifier: String
        var mountPoint: String?
        var volumeName: String?
        var mountedSnapshots: [Snapshot]?

        enum CodingKeys: String, CodingKey {
            case deviceIdentifier = "DeviceIdentifier"
            case mountPoint = "MountPoint"
            case volumeName = "VolumeName"
            case mountedSnapshots = "MountedSnapshots"
        }
    }

    struct Snapshot: Decodable, Sendable {
        var mountPoint: String?

        enum CodingKeys: String, CodingKey {
            case mountPoint = "SnapshotMountPoint"
        }
    }

    // `list` names the store `DeviceIdentifier`; `info` names it `APFSPhysicalStore`.
    struct StoreReference: Decodable, Sendable {
        var deviceIdentifier: String

        enum CodingKeys: String, CodingKey {
            case deviceIdentifier = "DeviceIdentifier"
        }
    }

    struct Volumes: Equatable, Sendable {
        var mountPoints: [String] = []
        var names: [String] = []

        mutating func add(mountPoint: String?, name: String?) {
            if let mountPoint, !mountPoint.isEmpty, !mountPoints.contains(mountPoint) {
                mountPoints.append(mountPoint)
            }
            if let name, !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }

        mutating func add(_ other: Volumes) {
            other.mountPoints.forEach { add(mountPoint: $0, name: nil) }
            other.names.forEach { add(mountPoint: nil, name: $0) }
        }
    }

    /// Volumes per whole disk. An APFS container's volumes are also credited to the
    /// disk holding its physical store, because erasing that disk destroys them.
    func volumesByWholeDisk() -> [String: Volumes] {
        var owner: [String: String] = [:]
        var result: [String: Volumes] = [:]
        for entry in entries {
            var volumes = Volumes()
            volumes.add(mountPoint: entry.mountPoint, name: entry.volumeName)
            for volume in (entry.partitions ?? []) + (entry.apfsVolumes ?? []) {
                owner[volume.deviceIdentifier] = entry.deviceIdentifier
                volumes.add(mountPoint: volume.mountPoint, name: volume.volumeName)
                for snapshot in volume.mountedSnapshots ?? [] {
                    volumes.add(mountPoint: snapshot.mountPoint, name: nil)
                }
            }
            result[entry.deviceIdentifier] = volumes
        }
        for entry in entries {
            guard let containerVolumes = result[entry.deviceIdentifier] else { continue }
            for store in entry.apfsPhysicalStores ?? [] {
                // A store is normally a partition; APFS directly on a whole disk is its own owner.
                let physical = owner[store.deviceIdentifier] ?? store.deviceIdentifier
                guard physical != entry.deviceIdentifier, result[physical] != nil else { continue }
                result[physical]?.add(containerVolumes)
            }
        }
        return result
    }
}
