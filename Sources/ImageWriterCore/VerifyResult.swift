import Foundation

/// The outcome of a verify pass in which every image byte matched.
public struct VerifyResult: Equatable, Sendable {
    /// Image bytes compared; the zero padding of the final block is not counted.
    public var bytesVerified: UInt64
    public var elapsedSeconds: TimeInterval

    public init(bytesVerified: UInt64, elapsedSeconds: TimeInterval) {
        self.bytesVerified = bytesVerified
        self.elapsedSeconds = elapsedSeconds
    }
}
