import os

/// Set from a task's cancellation handler and polled by blocking I/O loops running on
/// GCD threads, where `Task.isCancelled` is not available.
final class CancellationFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    var isCancelled: Bool {
        state.withLock { $0 }
    }
}
