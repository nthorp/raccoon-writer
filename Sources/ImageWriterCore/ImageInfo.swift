import Foundation

/// A validated source image, as chosen on the image step.
public struct ImageInfo: Equatable, Sendable {
    public var url: URL
    public var fileName: String
    public var sizeBytes: UInt64
    public var kind: ImageKind
    public var hasMBR: Bool
    public var hasGPT: Bool
    public var isISO9660: Bool
    public var bootWarning: BootWarning?

    public init(
        url: URL,
        fileName: String,
        sizeBytes: UInt64,
        kind: ImageKind,
        hasMBR: Bool,
        hasGPT: Bool,
        isISO9660: Bool,
        bootWarning: BootWarning?
    ) {
        self.url = url
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.hasMBR = hasMBR
        self.hasGPT = hasGPT
        self.isISO9660 = isISO9660
        self.bootWarning = bootWarning
    }
}
