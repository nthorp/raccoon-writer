import Foundation

/// A validated source image, as chosen on the image step.
public struct ImageInfo: Equatable, Sendable {
    public var url: URL
    public var fileName: String
    public var sizeBytes: UInt64
    /// The file as it was inspected. Writing and verifying fail if the file at `url`
    /// is no longer this one. Not optional, so the check can't be skipped.
    public var identity: FileIdentity
    /// Where the file system holding the image is mounted, as `statfs` reports it. A
    /// drive with a volume mounted there holds the image and can't be its target:
    /// the write starts by unmounting the drive, which takes the file with it.
    public var volumeMountPoint: String
    public var kind: ImageKind
    public var hasMBR: Bool
    public var hasGPT: Bool
    public var isISO9660: Bool
    public var bootWarning: BootWarning?

    public init(
        url: URL,
        fileName: String,
        sizeBytes: UInt64,
        identity: FileIdentity,
        volumeMountPoint: String,
        kind: ImageKind,
        hasMBR: Bool,
        hasGPT: Bool,
        isISO9660: Bool,
        bootWarning: BootWarning?
    ) {
        self.url = url
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.identity = identity
        self.volumeMountPoint = volumeMountPoint
        self.kind = kind
        self.hasMBR = hasMBR
        self.hasGPT = hasGPT
        self.isISO9660 = isISO9660
        self.bootWarning = bootWarning
    }
}
