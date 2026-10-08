import Foundation

/// Runs an external tool (diskutil) with an argument array. Never a shell string.
/// `ProcessCommandRunner` is the production implementation; tests use `FakeCommandRunner`.
public protocol CommandRunner: Sendable {
    /// Runs `executable` to completion. A nonzero exit status is returned, not thrown,
    /// because callers interpret diskutil's output (for example "busy") themselves.
    func run(_ executable: String, arguments: [String]) async throws -> CommandResult
}

/// What a finished command produced.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}
