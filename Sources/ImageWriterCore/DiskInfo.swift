import Foundation

/// One whole disk as diskutil describes it. Built by `DiskutilDiscovery`; whether it
/// may be written to is decided separately by `DiskFilter`.
public struct DiskInfo: Hashable, Sendable, Identifiable {
    /// Whole-disk BSD name, e.g. `disk4`.
    public var bsdName: String
    public var mediaName: String
    public var sizeBytes: UInt64
    public var blockSize: Int?
    /// diskutil's `BusProtocol`, e.g. `USB`, `PCI-Express`, `Secure Digital`, `Disk Image`.
    public var busProtocol: String?
    public var isInternal: Bool
    /// A built-in SD card slot with a card in it: the one internal disk `DiskFilter` may
    /// offer (`AGENTS.md`). Set by discovery only when all four diskutil keys say so; see
    /// `DiskInfo(DiskutilInfo, volumes:)`.
    public var isBuiltInCardReader: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    /// Disk images, RAM disks and APFS synthesized containers.
    public var isVirtual: Bool
    public var isWholeDisk: Bool
    /// An APFS synthesized container (it has physical stores). Never a write target:
    /// the physical disk underneath is.
    public var isAPFSContainer: Bool
    /// diskutil's `DiskUUID`. Usually absent on whole disks (seen in T01), so identity
    /// checks must not depend on it.
    public var mediaUUID: String?
    /// Mount points of every volume on this disk, including APFS volumes in containers
    /// whose physical store is one of its partitions.
    public var mountPoints: [String]
    public var volumeNames: [String]

    public init(
        bsdName: String,
        mediaName: String,
        sizeBytes: UInt64,
        blockSize: Int? = nil,
        busProtocol: String?,
        isInternal: Bool,
        isBuiltInCardReader: Bool = false,
        isRemovable: Bool,
        isEjectable: Bool,
        isVirtual: Bool,
        isWholeDisk: Bool,
        isAPFSContainer: Bool = false,
        mediaUUID: String? = nil,
        mountPoints: [String] = [],
        volumeNames: [String] = []
    ) {
        self.bsdName = bsdName
        self.mediaName = mediaName
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.busProtocol = busProtocol
        self.isInternal = isInternal
        self.isBuiltInCardReader = isBuiltInCardReader
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isVirtual = isVirtual
        self.isWholeDisk = isWholeDisk
        self.isAPFSContainer = isAPFSContainer
        self.mediaUUID = mediaUUID
        self.mountPoints = mountPoints
        self.volumeNames = volumeNames
    }

    public var id: String { bsdName }
    public var devicePath: String { "/dev/\(bsdName)" }
    public var rawDevicePath: String { "/dev/r\(bsdName)" }
}
