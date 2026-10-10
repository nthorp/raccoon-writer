import Foundation

/// Progress of a pass over the image: the write, and later the verify read-back.
public struct TransferProgress: Equatable, Sendable {
    /// Image bytes done. Zero padding of the final block is not counted.
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    /// Smoothed speed; nil until the first ~1 s measurement window has closed.
    public var bytesPerSecond: Double?

    public init(completedBytes: UInt64, totalBytes: UInt64, bytesPerSecond: Double?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    /// Nil while the speed is unknown or zero; 0 once everything is done.
    public var estimatedSecondsRemaining: Double? {
        guard completedBytes < totalBytes else { return 0 }
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }
}

public typealias WriteProgress = TransferProgress
