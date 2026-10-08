import Foundation

let diskutil = "/usr/sbin/diskutil"
let hdiutil = "/usr/bin/hdiutil"

enum TargetMode {
    /// Default: only an `hdiutil attach ram://…` RAM disk is accepted.
    case ramDiskOnly
    /// `--allow-physical-usb`: an external USB whole disk (for the optional real-stick run).
    case physicalUSB
}

struct DiskFacts {
    var bsdName: String
    var wholeDisk: Bool
    var isInternal: Bool
    var virtualOrPhysical: String
    var busProtocol: String
    var removable: Bool
    var ejectable: Bool
    var sizeBytes: UInt64
    var blockSize: Int
    var mediaName: String

    init(info: [String: Any]) {
        bsdName = info["DeviceIdentifier"] as? String ?? "?"
        wholeDisk = info["WholeDisk"] as? Bool ?? false
        // Missing "Internal" is treated as internal so the check fails closed.
        isInternal = info["Internal"] as? Bool ?? true
        virtualOrPhysical = info["VirtualOrPhysical"] as? String ?? "(absent)"
        busProtocol = info["BusProtocol"] as? String ?? "(absent)"
        removable = info["Removable"] as? Bool ?? false
        ejectable = info["Ejectable"] as? Bool ?? false
        sizeBytes = (info["Size"] as? NSNumber)?.uint64Value ?? 0
        blockSize = (info["DeviceBlockSize"] as? NSNumber)?.intValue ?? 0
        mediaName = info["MediaName"] as? String ?? "(absent)"
    }

    var summary: String {
        """
          BSD name:          \(bsdName)
          Media name:        \(mediaName)
          Size:              \(sizeBytes) bytes (\(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .binary)))
          Block size:        \(blockSize)
          WholeDisk:         \(wholeDisk)
          Internal:          \(isInternal)
          VirtualOrPhysical: \(virtualOrPhysical)
          BusProtocol:       \(busProtocol)
          Removable:         \(removable)   Ejectable: \(ejectable)
        """
    }
}

/// Parses `/dev/rdiskN` into `diskN`, rejecting anything else (partitions, paths, injection).
func bsdName(fromRawPath path: String) throws -> String {
    let pattern = #"^/dev/rdisk[0-9]+$"#
    guard path.range(of: pattern, options: .regularExpression) != nil else {
        throw SpikeError.usage("Target must look like /dev/rdiskN (whole raw disk), got \(path)")
    }
    return String(path.dropFirst("/dev/r".count))
}

/// Whole disks that back `/`: the APFS container plus the physical disks of its stores.
func bootWholeDisks() throws -> Set<String> {
    let root = try plistDictionary(diskutil, ["info", "-plist", "/"])
    var disks = Set<String>()
    if let parent = root["ParentWholeDisk"] as? String {
        disks.insert(parent)
    }
    let stores = root["APFSPhysicalStores"] as? [[String: Any]] ?? []
    for store in stores {
        guard let partition = store["APFSPhysicalStore"] as? String else { continue }
        let info = try plistDictionary(diskutil, ["info", "-plist", partition])
        if let parent = info["ParentWholeDisk"] as? String {
            disks.insert(parent)
        }
    }
    guard !disks.isEmpty else {
        throw SpikeError.refused("could not resolve the boot disk; refusing to continue")
    }
    return disks
}

/// True only if `hdiutil info` shows this exact whole disk as a `ram://` image.
func isRAMDisk(_ bsd: String) throws -> Bool {
    let info = try plistDictionary(hdiutil, ["info", "-plist"])
    let images = info["images"] as? [[String: Any]] ?? []
    for image in images {
        guard let imagePath = image["image-path"] as? String, imagePath.hasPrefix("ram://") else { continue }
        let entities = image["system-entities"] as? [[String: Any]] ?? []
        if entities.contains(where: { $0["dev-entry"] as? String == "/dev/\(bsd)" }) {
            return true
        }
    }
    return false
}

/// Every check must pass; any failure throws. Returns the facts for the summary.
func vetTarget(bsd: String, mode: TargetMode) throws -> DiskFacts {
    let facts = DiskFacts(info: try plistDictionary(diskutil, ["info", "-plist", bsd]))
    let boot = try bootWholeDisks()

    guard facts.bsdName == bsd else {
        throw SpikeError.refused("diskutil reports \(facts.bsdName), expected \(bsd)")
    }
    guard facts.wholeDisk else { throw SpikeError.refused("\(bsd) is not a whole disk") }
    guard !facts.isInternal else { throw SpikeError.refused("\(bsd) is internal") }
    guard !boot.contains(bsd) else { throw SpikeError.refused("\(bsd) backs the boot volume") }
    guard facts.blockSize > 0, facts.sizeBytes >= 2 * 1024 * 1024 else {
        throw SpikeError.refused("\(bsd) is too small or reports no block size")
    }

    switch mode {
    case .ramDiskOnly:
        // VirtualOrPhysical == Virtual alone is not enough: mounted .dmg files
        // (e.g. the iOS Simulator runtime) are Virtual too.
        guard facts.virtualOrPhysical == "Virtual" else {
            throw SpikeError.refused("\(bsd) is not a virtual disk (VirtualOrPhysical = \(facts.virtualOrPhysical))")
        }
        guard try isRAMDisk(bsd) else {
            throw SpikeError.refused("\(bsd) is virtual but not a ram:// disk (hdiutil info)")
        }
    case .physicalUSB:
        guard facts.virtualOrPhysical != "Virtual" else {
            throw SpikeError.refused("\(bsd) is virtual; omit --allow-physical-usb for RAM disks")
        }
        guard facts.busProtocol == "USB" else {
            throw SpikeError.refused("\(bsd) is not on the USB bus (BusProtocol = \(facts.busProtocol))")
        }
        guard facts.removable || facts.ejectable else {
            throw SpikeError.refused("\(bsd) is neither removable nor ejectable")
        }
    }
    return facts
}
