import Foundation
import os

/// `DiskDiscovery` backed by `diskutil list -plist` plus `diskutil info -plist` per whole disk.
public struct DiskutilDiscovery: DiskDiscovery {
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "discovery")

    private let diskutil: Diskutil

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        diskutil = Diskutil(runner: runner)
    }

    public func listDisks() async throws -> [DiskInfo] {
        let list = try await diskutil.list()
        let volumes = list.volumesByWholeDisk()
        let names = list.wholeDisks.filter { name in
            guard BSDName.isWholeDisk(name) else {
                Self.log.error("Skipping invalid whole-disk name from diskutil list: \(name, privacy: .public)")
                return false
            }
            return true
        }

        return try await withThrowingTaskGroup(of: (Int, DiskInfo?).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask {
                    (index, try await describe(name, volumes: volumes[name] ?? DiskutilList.Volumes()))
                }
            }
            var described: [(Int, DiskInfo)] = []
            for try await case let (index, disk?) in group {
                described.append((index, disk))
            }
            return described.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Returns nil for a disk that vanished or that diskutil describes inconsistently.
    /// Leaving a disk out is always safe; failing to run diskutil at all is not, so
    /// `CommandRunnerError` propagates.
    private func describe(_ name: String, volumes: DiskutilList.Volumes) async throws -> DiskInfo? {
        let info: DiskutilInfo
        do {
            info = try await diskutil.info(name)
        } catch let error as DiskDiscoveryError {
            Self.log.error("Skipping \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard info.deviceIdentifier == name else {
            Self.log.error("Skipping \(name, privacy: .public): diskutil described \(info.deviceIdentifier, privacy: .public)")
            return nil
        }
        return DiskInfo(info, volumes: volumes)
    }
}

extension DiskInfo {
    /// Missing safety flags take the restrictive value: no `Internal` key means internal,
    /// no `WholeDisk` key means not a whole disk.
    init(_ info: DiskutilInfo, volumes: DiskutilList.Volumes) {
        let stores = info.apfsPhysicalStores ?? []
        var mountPoints = volumes.mountPoints
        if let own = info.mountPoint, !own.isEmpty, !mountPoints.contains(own) {
            mountPoints.insert(own, at: 0)
        }
        self.init(
            bsdName: info.deviceIdentifier,
            mediaName: info.mediaName ?? "",
            sizeBytes: info.size ?? info.totalSize ?? 0,
            blockSize: info.deviceBlockSize,
            busProtocol: info.busProtocol,
            isInternal: info.isInternal ?? true,
            isRemovable: (info.removable ?? false) || (info.removableMedia ?? false),
            isEjectable: info.ejectable ?? false,
            // T01: internal disks report "Unknown", so only "Virtual" counts as virtual.
            isVirtual: info.virtualOrPhysical == "Virtual" || info.busProtocol == "Disk Image",
            isWholeDisk: info.wholeDisk ?? false,
            isAPFSContainer: !stores.isEmpty || info.apfsContainerReference == info.deviceIdentifier,
            mediaUUID: info.diskUUID,
            mountPoints: mountPoints,
            volumeNames: volumes.names
        )
    }
}
