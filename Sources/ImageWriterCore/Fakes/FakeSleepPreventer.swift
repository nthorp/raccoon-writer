import Foundation

/// A `SleepPreventer` that only counts, for tests and the debug Simulate mode.
public final class FakeSleepPreventer: SleepPreventer, @unchecked Sendable {
    private let lock = NSLock()
    private var begun: [String] = []
    private var endedCount = 0

    public init() {}

    /// The reason of every activity begun, in order.
    public var reasons: [String] { lock.withLock { begun } }
    /// Activities begun and not yet ended.
    public var activeCount: Int { lock.withLock { begun.count - endedCount } }

    public func preventSleep(reason: String) -> any SleepActivity {
        lock.withLock { begun.append(reason) }
        return Activity(owner: self)
    }

    fileprivate func activityEnded() {
        lock.withLock { endedCount += 1 }
    }

    private final class Activity: SleepActivity, @unchecked Sendable {
        private let lock = NSLock()
        private var owner: FakeSleepPreventer?

        init(owner: FakeSleepPreventer) {
            self.owner = owner
        }

        func end() {
            let owner = lock.withLock { () -> FakeSleepPreventer? in
                defer { self.owner = nil }
                return self.owner
            }
            owner?.activityEnded()
        }
    }
}
