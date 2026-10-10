import Foundation

/// A property that identifies the physical medium behind a BSD name. If one differs
/// between the confirmed disk and a fresh query, a different drive now has that name.
/// Mount points and volume names are not identity: they change on their own.
public enum DiskIdentityField: Equatable, Sendable, CaseIterable {
    case size
    case mediaName
    case blockSize
    case busProtocol
    case mediaUUID

    public var label: String {
        switch self {
        case .size: return "size"
        case .mediaName: return "name"
        case .blockSize: return "block size"
        case .busProtocol: return "connection type"
        case .mediaUUID: return "media identifier"
        }
    }
}

extension DiskInfo {
    /// The first identity field that differs from `other`, or nil if none does.
    /// Optional fields are compared as-is, so a value that appeared or vanished counts
    /// as a difference.
    public func identityDifference(from other: DiskInfo) -> DiskIdentityField? {
        if sizeBytes != other.sizeBytes { return .size }
        if mediaName != other.mediaName { return .mediaName }
        if blockSize != other.blockSize { return .blockSize }
        if busProtocol != other.busProtocol { return .busProtocol }
        if mediaUUID != other.mediaUUID { return .mediaUUID }
        return nil
    }
}
