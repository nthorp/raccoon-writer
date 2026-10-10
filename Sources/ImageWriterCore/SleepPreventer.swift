import Foundation

/// Keeps the Mac from idle-sleeping while a run is in progress. A sleep mid-write would
/// stall the USB transfer and could leave the drive half written.
public protocol SleepPreventer: Sendable {
    /// Sleep stays prevented until the returned activity is ended.
    func preventSleep(reason: String) -> any SleepActivity
}

public protocol SleepActivity: Sendable {
    /// Lets the Mac sleep again. Calling it more than once is harmless.
    func end()
}

/// `ProcessInfo.beginActivity` with idle system sleep disabled. The display may still sleep.
public struct ProcessInfoSleepPreventer: SleepPreventer {
    public init() {}

    public func preventSleep(reason: String) -> any SleepActivity {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
        return ProcessInfoActivity(token: token)
    }
}

private final class ProcessInfoActivity: SleepActivity, @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`; nil once ended, so `endActivity` runs exactly once.
    private var token: NSObjectProtocol?

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func end() {
        let ended = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let ended {
            ProcessInfo.processInfo.endActivity(ended)
        }
    }
}
