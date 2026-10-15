import Foundation
@testable import ImageWriterCore

/// The fixture machine in `Fixtures/diskutil/`:
/// - `disk0` internal SSD; `disk3` its APFS container holding `/` (real captures, macOS 26.3.1)
/// - `disk4` USB stick with two mounted partitions
/// - `disk5` Thunderbolt (PCI-Express) SSD; `disk6` its APFS container, mounted at /Volumes/Backup
/// - `disk7` SD card in a built-in SDXC slot (`Internal = true`, Secure Digital bus)
/// - `disk8` mounted disk image
/// - `disk9` SD card in a USB card reader
/// The disk4–disk6 and disk8 plists are hand-written from the keys seen on real captures.
/// disk7 is hand-written around the H14 capture's values (T29). `info-disk9` is a real
/// capture (H14, 2026-10-14) with only the disk number changed.
enum DiskutilFixtures {
    static let diskutil = "/usr/sbin/diskutil"
    static let wholeDisks = ["disk0", "disk3", "disk4", "disk5", "disk6", "disk7", "disk8", "disk9"]

    struct Missing: Error {
        let name: String
    }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures/diskutil") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func ok(_ fixture: String) throws -> CommandResult {
        CommandResult(status: 0, stdout: try data(fixture))
    }

    /// diskutil's real reply for a disk that does not exist.
    static func notFound() throws -> CommandResult {
        CommandResult(status: 1, stdout: try data("info-missing"))
    }

    static func plist(_ object: Any) throws -> CommandResult {
        CommandResult(status: 0, stdout: try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0))
    }

    static func info(_ target: String) -> [String] {
        [diskutil, "info", "-plist", target]
    }

    static let list = [diskutil, "list", "-plist"]

    static func responses() throws -> [[String]: CommandResult] {
        var responses: [[String]: CommandResult] = [
            list: try ok("list"),
            info("/"): try ok("info-root"),
            info("disk0s2"): try ok("info-disk0s2"),
        ]
        for disk in wholeDisks {
            responses[info(disk)] = try ok("info-\(disk)")
        }
        return responses
    }

    static func runner(overriding overrides: [[String]: CommandResult] = [:]) throws -> FakeCommandRunner {
        FakeCommandRunner(responses: try responses().merging(overrides) { _, new in new })
    }

    /// A fixture plist as a mutable dictionary, for variants.
    static func dictionary(_ fixture: String) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: try data(fixture), format: nil)
        guard let dictionary = object as? [String: Any] else { throw Missing(name: fixture) }
        return dictionary
    }

    /// An override replying to `diskutil info -plist <disk>` with its fixture changed.
    static func infoVariant(_ disk: String, setting changes: [String: Any] = [:], removing removals: [String] = []) throws -> [[String]: CommandResult] {
        var info = try dictionary("info-\(disk)").merging(changes) { _, new in new }
        for key in removals { info.removeValue(forKey: key) }
        return [self.info(disk): try plist(info)]
    }
}

extension DiskInfo {
    /// A plain external USB stick that passes the default filter. Tests change one field.
    /// Coordinator tests pass the size of their fake device, which the open is checked against.
    static func usbStick(_ bsdName: String = "disk4", sizeBytes: UInt64 = 30_752_636_928) -> DiskInfo {
        DiskInfo(
            bsdName: bsdName,
            mediaName: "SanDisk Ultra",
            sizeBytes: sizeBytes,
            blockSize: 512,
            busProtocol: "USB",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isVirtual: false,
            isWholeDisk: true,
            mountPoints: ["/Volumes/STICK"],
            volumeNames: ["STICK"]
        )
    }
}

extension DiskInfo {
    /// A card in a built-in SDXC slot, as discovery describes the H14 capture: internal,
    /// and allowed only because it is a built-in card reader.
    static func builtInSDCard(_ bsdName: String = "disk7") -> DiskInfo {
        DiskInfo(
            bsdName: bsdName,
            mediaName: "Built In SDXC Reader",
            sizeBytes: 64_021_856_256,
            blockSize: 512,
            busProtocol: "Secure Digital",
            isInternal: true,
            isBuiltInCardReader: true,
            isRemovable: true,
            isEjectable: true,
            isVirtual: false,
            isWholeDisk: true,
            mountPoints: ["/Volumes/CAMERA"],
            volumeNames: ["CAMERA"]
        )
    }
}

extension BootDiskSet {
    static let fixture = BootDiskSet(["disk0", "disk3"])!
}
