#if DEBUG
import Foundation

/// Debug Simulate mode only. The fake drives the drive list offers, each with a scripted
/// outcome, so every screen can be reached without touching a real disk.
public enum SimulatedDrive: String, CaseIterable, Sendable {
    /// The boot disk. Listed by discovery and always hidden by the filter.
    case internalDisk
    case working
    case removedMidWrite
    case verifyMismatch
    case promptCancelled
    /// Smaller than most images, for the "drive too small" check before the confirm screen.
    case tooSmall
    /// Not USB, so it appears only with "Show all external disks".
    case thunderbolt
    /// Ejectable but not removable, as USB hard drives report, so it is listed by default
    /// with the large-drive warning. Otherwise behaves like `working`.
    case usbHardDrive
    /// The password dialog succeeds, then the open is refused as when the Removable
    /// Volumes privacy prompt was denied.
    case privacyBlocked

    static let writeBytesPerSecond = 40_000_000.0
    static let readBytesPerSecond = 80_000_000.0
    /// With 4 MiB chunks this fails about 25 MB in.
    static let failingWriteCall = 6
    static let corruptReadCall = 3

    public var bsdName: String {
        switch self {
        case .internalDisk: return "disk0"
        case .working: return "disk90"
        case .removedMidWrite: return "disk91"
        case .verifyMismatch: return "disk92"
        case .promptCancelled: return "disk93"
        case .tooSmall: return "disk94"
        case .thunderbolt: return "disk95"
        case .usbHardDrive: return "disk96"
        case .privacyBlocked: return "disk97"
        }
    }

    public var disk: DiskInfo {
        switch self {
        case .internalDisk:
            return DiskInfo(
                bsdName: bsdName, mediaName: mediaName, sizeBytes: 1_000_555_581_440, blockSize: 4096,
                busProtocol: "Apple Fabric", isInternal: true, isRemovable: false, isEjectable: false,
                isVirtual: false, isWholeDisk: true, mountPoints: ["/"], volumeNames: ["Macintosh HD"]
            )
        case .thunderbolt:
            return DiskInfo(
                bsdName: bsdName, mediaName: mediaName, sizeBytes: 500_107_862_016, blockSize: 512,
                busProtocol: "PCI-Express", isInternal: false, isRemovable: false, isEjectable: true,
                isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/Backup"], volumeNames: ["Backup"]
            )
        case .usbHardDrive:
            return DiskInfo(
                bsdName: bsdName, mediaName: mediaName, sizeBytes: 1_000_204_886_016, blockSize: 512,
                busProtocol: "USB", isInternal: false, isRemovable: false, isEjectable: true,
                isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/SIM96"], volumeNames: ["SIM96"]
            )
        default:
            return DiskInfo(
                bsdName: bsdName, mediaName: mediaName, sizeBytes: sizeBytes, blockSize: 512,
                busProtocol: "USB", isInternal: false, isRemovable: true, isEjectable: true,
                isVirtual: false, isWholeDisk: true,
                mountPoints: ["/Volumes/SIM\(bsdName.dropFirst(4))"], volumeNames: ["SIM\(bsdName.dropFirst(4))"]
            )
        }
    }

    private var mediaName: String {
        switch self {
        case .working: return "Simulated USB Stick (works)"
        case .removedMidWrite: return "Simulated USB Stick (pulled out mid-write)"
        case .verifyMismatch: return "Simulated USB Stick (bad data on read-back)"
        case .promptCancelled: return "Simulated USB Stick (password dialog cancelled)"
        case .tooSmall: return "Simulated USB Stick (16 MB)"
        case .internalDisk: return "Simulated Internal SSD"
        case .thunderbolt: return "Simulated Thunderbolt SSD"
        case .usbHardDrive: return "Simulated USB Hard Drive (1 TB)"
        case .privacyBlocked: return "Simulated USB Stick (privacy settings blocked)"
        }
    }

    private var sizeBytes: UInt64 {
        self == .tooSmall ? 16_000_000 : 16_008_609_792
    }

    init?(bsdName: String) {
        guard let drive = Self.allCases.first(where: { $0.bsdName == bsdName }) else { return nil }
        self = drive
    }

    /// The device an open of this drive returns: a sparse temp file of the drive's size.
    func openDevice(in directory: URL) throws -> any OpenedDevice {
        var faults = FileBackedDevice.Faults()
        if self == .removedMidWrite {
            faults.failWrite = .init(call: Self.failingWriteCall, code: ENXIO)
        }
        let blockSize = disk.blockSize ?? 512
        let file = try FileBackedDevice(
            blockSize: blockSize,
            blockCount: disk.sizeBytes / UInt64(blockSize),
            faults: faults,
            directory: directory
        )
        return SimulatedDevice(
            inner: file,
            writeBytesPerSecond: Self.writeBytesPerSecond,
            readBytesPerSecond: Self.readBytesPerSecond,
            corruptReadCall: self == .verifyMismatch ? Self.corruptReadCall : nil
        )
    }
}
#endif
