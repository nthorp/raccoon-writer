import Foundation

/// A non-blocking concern about whether an image will boot once written to USB.
public enum BootWarning: Equatable, Sendable {
    /// An ISO 9660 image with no MBR or GPT: a CD/DVD-only ISO that firmware usually
    /// cannot boot from a USB drive.
    case mayNotBootFromUSB

    public var message: String {
        switch self {
        case .mayNotBootFromUSB:
            return "This ISO has no partition table, so it may not boot from a USB drive. It can still be written."
        }
    }
}
