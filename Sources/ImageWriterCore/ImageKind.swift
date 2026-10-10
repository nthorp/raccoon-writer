import Foundation

/// The image formats ISO Sword writes. Both are copied to the drive byte for byte.
public enum ImageKind: String, Equatable, Sendable {
    case iso
    case img

    /// Matches `.iso` / `.img` case-insensitively; anything else is unsupported.
    public init?(pathExtension: String) {
        self.init(rawValue: pathExtension.lowercased())
    }
}
