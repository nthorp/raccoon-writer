import Foundation

/// Boot-relevant signatures found in the first bytes of an image.
struct ImageSignatures: Equatable, Sendable {
    /// How much of the image detection needs; covers the ISO 9660 primary volume descriptor.
    static let headerLength = 64 * 1024

    var hasMBR: Bool
    var hasGPT: Bool
    var isISO9660: Bool

    /// `header` is the start of the image; it may be shorter than `headerLength`,
    /// in which case signatures past its end are simply absent.
    init(header: [UInt8]) {
        hasMBR = Self.matches(header, [0x55, 0xAA], at: 510)
        hasGPT = Self.matches(header, Array("EFI PART".utf8), at: 512)
        isISO9660 = Self.matches(header, Array("CD001".utf8), at: 0x8001)
    }

    var bootWarning: BootWarning? {
        isISO9660 && !hasMBR && !hasGPT ? .mayNotBootFromUSB : nil
    }

    private static func matches(_ header: [UInt8], _ signature: [UInt8], at offset: Int) -> Bool {
        header.count >= offset + signature.count
            && header[offset ..< offset + signature.count].elementsEqual(signature)
    }
}
