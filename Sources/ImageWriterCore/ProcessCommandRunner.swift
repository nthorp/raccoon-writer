import Foundation
import os

/// Production `CommandRunner` built on `Process`, with a timeout so a hung diskutil
/// can't stall disk discovery, the safety check, unmount or eject forever.
///
/// Every wait is bounded, so a call returns or throws within `timeout` + 2 × `killGrace`.
/// After the timeout the command gets SIGTERM, then SIGKILL after `killGrace`, then
/// another `killGrace` to exit before it is abandoned. A command that exits in time
/// gives its output readers `killGrace` to finish, in case a grandchild inherited
/// stdout or stderr and keeps the pipe open.
public struct ProcessCommandRunner: CommandRunner {
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "commands")

    public var timeout: TimeInterval
    /// How long each escalation step waits. Internal so tests can shorten it.
    let killGrace: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.init(timeout: timeout, killGrace: 2)
    }

    init(timeout: TimeInterval, killGrace: TimeInterval) {
        self.timeout = timeout
        self.killGrace = killGrace
    }

    public func run(_ executable: String, arguments: [String]) async throws -> CommandResult {
        // Blocking waits run on a GCD thread, not the cooperative pool.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments: arguments) })
            }
        }
    }

    private func runBlocking(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(executable: executable, message: error.localizedDescription)
        }

        // Drain both pipes concurrently; a full pipe would otherwise block the child.
        let readers = DispatchGroup()
        let stdout = OutputCollector(stdoutPipe.fileHandleForReading, group: readers)
        let stderr = OutputCollector(stderrPipe.fileHandleForReading, group: readers)

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                if exited.wait(timeout: .now() + killGrace) == .timedOut {
                    Self.log.error("\(executable, privacy: .public) did not exit after SIGKILL; giving up on it")
                }
            }
            // The output of a command that didn't finish isn't needed.
            throw CommandRunnerError.timedOut(executable: executable, seconds: timeout)
        }
        // If the readers don't finish, they are left to finish on their own: closing their
        // handles under a blocked read could close a descriptor number reused elsewhere.
        guard readers.wait(timeout: .now() + killGrace) == .success else {
            throw CommandRunnerError.outputUnreadable(
                executable: executable,
                message: "it stayed open after the command exited, probably held by a process the command started."
            )
        }
        if process.terminationReason == .uncaughtSignal {
            throw CommandRunnerError.terminated(executable: executable, signal: process.terminationStatus)
        }
        do {
            return CommandResult(status: process.terminationStatus, stdout: try stdout.data.get(), stderr: try stderr.data.get())
        } catch {
            throw CommandRunnerError.outputUnreadable(executable: executable, message: error.localizedDescription)
        }
    }
}

/// Reads a pipe to EOF on a background thread.
private final class OutputCollector: @unchecked Sendable {
    // Written once by the reader before `group.leave()`, read only after `group.wait()`.
    private(set) var data: Result<Data, Error> = .success(Data())

    init(_ handle: FileHandle, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.data = Result { try handle.readToEnd() ?? Data() }
            group.leave()
        }
    }
}
