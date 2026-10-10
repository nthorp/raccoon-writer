import Foundation

/// A source of monotonic seconds. Injected so speed and throttling tests can use a fake clock.
public struct MonotonicClock: Sendable {
    public var now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
    }

    /// Counts time asleep too, so a stall across sleep is not reported as speed.
    public static let system = MonotonicClock {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
