import Foundation

/// A `CommandRunner` that answers from canned results (fixture plists), for tests
/// and the debug "Simulate" mode. It never launches anything.
public final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    public typealias Handler = @Sendable (_ executable: String, _ arguments: [String]) throws -> CommandResult

    private let lock = NSLock()
    private let handler: Handler
    private var calls: [[String]] = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Keys are `[executable] + arguments`. Unknown commands exit 1, as diskutil does
    /// for a disk that no longer exists.
    public convenience init(responses: [[String]: CommandResult]) {
        self.init { executable, arguments in
            let key = [executable] + arguments
            return responses[key]
                ?? CommandResult(status: 1, stderr: Data("FakeCommandRunner: no response for \(key)\n".utf8))
        }
    }

    /// Every command run so far, as `[executable] + arguments`, in order.
    public var invocations: [[String]] { lock.withLock { calls } }

    public func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        lock.withLock { calls.append([executable] + arguments) }
        return try handler(executable, arguments)
    }
}
