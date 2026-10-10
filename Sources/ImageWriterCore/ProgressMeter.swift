import Foundation

/// Turns byte counts into `TransferProgress` updates, at most about 10 per second.
struct ProgressMeter: Sendable {
    static let minimumInterval: TimeInterval = 0.1

    let totalBytes: UInt64
    private var speed: SpeedEstimator
    private var lastPublished: TimeInterval?

    init(totalBytes: UInt64, startTime: TimeInterval) {
        self.totalBytes = totalBytes
        speed = SpeedEstimator(startTime: startTime)
    }

    /// The progress to publish for `completedBytes` at `time`, or nil if one went out too
    /// recently. The first update and the one that reaches `totalBytes` always publish,
    /// so the UI shows 0% at once and never ends short of 100%.
    mutating func update(completedBytes: UInt64, at time: TimeInterval) -> TransferProgress? {
        speed.record(totalBytes: completedBytes, at: time)
        let isLast = completedBytes >= totalBytes
        if !isLast, let lastPublished, time - lastPublished < Self.minimumInterval {
            return nil
        }
        lastPublished = time
        return TransferProgress(completedBytes: completedBytes, totalBytes: totalBytes, bytesPerSecond: speed.bytesPerSecond)
    }
}
