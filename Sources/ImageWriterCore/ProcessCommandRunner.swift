import Foundation

/// Production `CommandRunner` built on `Process`, with a timeout so a hung diskutil
/// can't stall disk discovery forever.
public struct ProcessCommandRunner: CommandRunner {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
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

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            exited.wait()
        }
        readers.wait()

        if timedOut {
            throw CommandRunnerError.timedOut(executable: executable, seconds: timeout)
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
