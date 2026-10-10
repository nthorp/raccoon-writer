import Foundation

/// The drive was written and verified but could not be ejected. Not a failed write.
public struct EjectWarning: Equatable, Sendable {
    public var bsdName: String
    /// Why the eject failed, for logs and a details line.
    public var reason: String

    public init(bsdName: String, reason: String) {
        self.bsdName = bsdName
        self.reason = reason
    }

    /// User-facing text for the done screen.
    public var message: String {
        "The drive was written and verified, but macOS could not eject it. Eject it in Finder before removing it."
    }
}
