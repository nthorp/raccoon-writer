import Foundation

/// The subset of `diskutil info -plist <target>` we read. Every key is optional because
/// diskutil omits keys freely; a key with an unexpected type fails decoding.
struct DiskutilInfo: Decodable, Sendable {
    var deviceIdentifier: String
    var parentWholeDisk: String?
    var wholeDisk: Bool?
    var mediaName: String?
    var size: UInt64?
    var totalSize: UInt64?
    var deviceBlockSize: Int?
    var busProtocol: String?
    var isInternal: Bool?
    var removable: Bool?
    var removableMedia: Bool?
    var ejectable: Bool?
    var virtualOrPhysical: String?
    var diskUUID: String?
    var mountPoint: String?
    var volumeName: String?
    var filesystemType: String?
    var apfsContainerReference: String?
    var apfsPhysicalStores: [Store]?

    struct Store: Decodable, Sendable {
        var identifier: String

        enum CodingKeys: String, CodingKey {
            case identifier = "APFSPhysicalStore"
        }
    }

    enum CodingKeys: String, CodingKey {
        case deviceIdentifier = "DeviceIdentifier"
        case parentWholeDisk = "ParentWholeDisk"
        case wholeDisk = "WholeDisk"
        case mediaName = "MediaName"
        case size = "Size"
        case totalSize = "TotalSize"
        case deviceBlockSize = "DeviceBlockSize"
        case busProtocol = "BusProtocol"
        case isInternal = "Internal"
        case removable = "Removable"
        case removableMedia = "RemovableMedia"
        case ejectable = "Ejectable"
        case virtualOrPhysical = "VirtualOrPhysical"
        case diskUUID = "DiskUUID"
        case mountPoint = "MountPoint"
        case volumeName = "VolumeName"
        case filesystemType = "FilesystemType"
        case apfsContainerReference = "APFSContainerReference"
        case apfsPhysicalStores = "APFSPhysicalStores"
    }
}
