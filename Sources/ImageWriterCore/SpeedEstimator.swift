import Foundation

/// Bytes per second, smoothed with an exponential moving average over ~1 s windows
/// so that one slow or fast chunk does not make the displayed speed jump around.
struct SpeedEstimator: Sendable {
    static let window: TimeInterval = 1
    /// Weight of the newest window in the average.
    static let smoothing = 0.3

    private var windowStart: TimeInterval
    private var windowStartBytes: UInt64
    private(set) var bytesPerSecond: Double?

    init(startTime: TimeInterval, startBytes: UInt64 = 0) {
        windowStart = startTime
        windowStartBytes = startBytes
    }

    /// Records that `totalBytes` were done by `time`. A window closes at the first
    /// sample at least `window` seconds after it opened, so slow chunks still count.
    mutating func record(totalBytes: UInt64, at time: TimeInterval) {
        let elapsed = time - windowStart
        guard elapsed >= Self.window, totalBytes >= windowStartBytes else { return }
        let rate = Double(totalBytes - windowStartBytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { Self.smoothing * rate + (1 - Self.smoothing) * $0 } ?? rate
        windowStart = time
        windowStartBytes = totalBytes
    }
}
