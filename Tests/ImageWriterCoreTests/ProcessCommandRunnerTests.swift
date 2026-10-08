import Foundation
import Testing
@testable import ImageWriterCore

struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner(timeout: 10)

    @Test func capturesStatusAndBothStreams() async throws {
        let result = try await runner.run("/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdoutText == "out")
        #expect(result.stderrText == "err")
    }

    @Test func argumentsAreNotInterpretedByAShell() async throws {
        let result = try await runner.run("/bin/echo", arguments: ["disk4; ls", "$HOME"])
        #expect(result.status == 0)
        #expect(result.stdoutText == "disk4; ls $HOME\n")
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        // Well past the 64 KiB pipe buffer on each stream at once.
        let script = "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2"
        let result = try await runner.run("/bin/sh", arguments: ["-c", script])
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func timeoutTerminatesTheCommand() async {
        let start = Date()
        await #expect(throws: CommandRunnerError.timedOut(executable: "/bin/sleep", seconds: 0.3)) {
            _ = try await ProcessCommandRunner(timeout: 0.3).run("/bin/sleep", arguments: ["30"])
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func missingExecutableIsLaunchFailure() async {
        do {
            _ = try await runner.run("/nonexistent/isosword/diskutil", arguments: [])
            Issue.record("expected a launch failure")
        } catch CommandRunnerError.launchFailed(let executable, _) {
            #expect(executable == "/nonexistent/isosword/diskutil")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func signalIsTermination() async {
        await #expect(throws: CommandRunnerError.terminated(executable: "/bin/sh", signal: 9)) {
            _ = try await runner.run("/bin/sh", arguments: ["-c", "kill -9 $$"])
        }
    }
}
