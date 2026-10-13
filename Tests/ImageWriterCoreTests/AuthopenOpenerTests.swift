import Foundation
import Testing
@testable import ImageWriterCore

/// No test here runs the real authopen. Process tests point `AuthopenOpener` at a
/// stand-in shell script that mimics authopen's failure behavior from T01.
struct AuthopenOpenerTests {
    // MARK: - Error mapping from canned (status, stderr) pairs

    @Test func cancelMapsToUserCancelled() {
        let stderr = "AuthorizationCreate failed: The authorization was canceled by the user.\n"
        #expect(AuthopenOpener.failure(for: .exited(1), stderr: stderr) == .userCancelled)
        #expect(AuthopenOpener.failure(for: .exited(1), stderr: "cancelled by the user") == .userCancelled)
    }

    @Test func busyMapsToDeviceBusy() {
        #expect(AuthopenOpener.failure(for: .exited(1), stderr: "open: Resource busy") == .deviceBusy)
    }

    @Test(arguments: ["open: Operation not permitted", "open: Permission denied", "AuthorizationCopyRights denied"])
    func refusalMapsToPermissionDenied(_ stderr: String) {
        #expect(AuthopenOpener.failure(for: .exited(1), stderr: stderr) == .permissionDenied)
    }

    @Test func unrecognizedTextIsGenericFailure() {
        #expect(AuthopenOpener.failure(for: .exited(1), stderr: "  something odd\n")
            == .authopenFailed(status: 1, message: "something odd"))
        // A clean exit without a descriptor is still a failure.
        #expect(AuthopenOpener.failure(for: .exited(0), stderr: "") == .authopenFailed(status: 0, message: ""))
    }

    @Test func signalIsTermination() {
        #expect(AuthopenOpener.failure(for: .signalled(9), stderr: "") == .authopenTerminated(signal: 9))
    }

    @Test func waitStatusDecoding() {
        #expect(AuthopenOpener.Termination(waitStatus: 0) == .exited(0))
        #expect(AuthopenOpener.Termination(waitStatus: 0x100) == .exited(1))
        #expect(AuthopenOpener.Termination(waitStatus: 0x7f00) == .exited(127))
        #expect(AuthopenOpener.Termination(waitStatus: 9) == .signalled(9))
        #expect(AuthopenOpener.Termination(waitStatus: 15 | 0x80) == .signalled(15))
    }

    @Test func productionUsesSystemAuthopen() {
        #expect(AuthopenOpener().executable == "/usr/libexec/authopen")
        #expect(AuthopenOpener().authorizer is SecurityAuthorizer)
    }

    // MARK: - Spawning a stand-in

    @Test func invalidNameThrowsBeforeSpawning() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-marker-\(UUID().uuidString)")
        let script = try StandIn("touch '\(marker.path)'; exit 1")
        let standIn = opener(script.path)
        for name in ["disk4s1", "/dev/disk4", "disk4;rm", "rdisk4", ""] {
            await #expect(throws: DeviceOpenError.invalidDiskName(name)) {
                _ = try await standIn.openForReadWrite(bsdName: name)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func passesExactArguments() async throws {
        let script = try StandIn("echo \"$@\" >&2; exit 3")
        await #expect(throws: DeviceOpenError.authopenFailed(status: 3, message: "-stdoutpipe -extauth -o 2 /dev/rdisk42")) {
            _ = try await opener(script.path).openForReadWrite(bsdName: "disk42")
        }
    }

    @Test func cancelFromStandInMapsToUserCancelled() async throws {
        let script = try StandIn("echo 'AuthorizationCreate failed: The authorization was canceled by the user.' >&2; exit 1")
        await #expect(throws: DeviceOpenError.userCancelled) {
            _ = try await opener(script.path).openForReadWrite(bsdName: "disk4")
        }
    }

    @Test func cleanExitWithoutDescriptorFails() async throws {
        let script = try StandIn("echo not-a-descriptor; exit 0")
        await #expect(throws: DeviceOpenError.authopenFailed(status: 0, message: "")) {
            _ = try await opener(script.path).openForReadWrite(bsdName: "disk4")
        }
    }

    @Test func killedStandInIsTermination() async throws {
        let script = try StandIn("kill -9 $$")
        await #expect(throws: DeviceOpenError.authopenTerminated(signal: 9)) {
            _ = try await opener(script.path).openForReadWrite(bsdName: "disk4")
        }
    }

    @Test func childDoesNotInheritUnrelatedDescriptors() async throws {
        // Descriptors above 2 must be closed in the child (POSIX_SPAWN_CLOEXEC_DEFAULT).
        // Compare inodes, since the child may reuse the same number for something else.
        let (url, fd) = try makeTempFile()
        defer {
            close(fd)
            unlink(url.path)
        }
        // Inheritable, so only the spawn attribute can keep it out of the child.
        #expect(fcntl(fd, F_SETFD, 0) == 0)
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        let script = try StandIn("stat -L -f %i /dev/fd/\(fd) 1>&2 2>/dev/null; exit 4")
        do {
            _ = try await opener(script.path).openForReadWrite(bsdName: "disk4")
            Issue.record("expected a failure")
        } catch DeviceOpenError.authopenFailed(let status, let message) {
            #expect(status == 4)
            #expect(message != String(info.st_ino))
        }
    }

    @Test func missingExecutableIsSpawnError() async {
        await #expect(throws: DeviceOpenError.posix(operation: "posix_spawn", code: ENOENT)) {
            _ = try await opener("/nonexistent/isosword/authopen").openForReadWrite(bsdName: "disk4")
        }
    }

    // MARK: - External authorization (-extauth)

    @Test(arguments: [
        DeviceOpenError.userCancelled,
        .permissionDenied,
        .authorizationFailed(status: errAuthorizationInternal),
    ])
    func failedAuthorizationNeverSpawns(_ error: DeviceOpenError) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-marker-\(UUID().uuidString)")
        let script = try StandIn("touch '\(marker.path)'; exit 1")
        let authorizer = FakeDeviceAuthorizer(error: error)
        await #expect(throws: error) {
            _ = try await AuthopenOpener(executable: script.path, authorizer: authorizer).openForReadWrite(bsdName: "disk4")
        }
        #expect(authorizer.requestedPaths == ["/dev/rdisk4"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func standInReceivesExtauthAndExactlyTheExternalForm() async throws {
        // Reads stdin to EOF, so it also proves the write end is closed after 32 bytes.
        let script = try StandIn("printf '%s|' \"$*\" >&2; od -An -v -tx1 | tr -d ' \\n' >&2; exit 3")
        let authorizer = FakeDeviceAuthorizer()
        let hex = FakeDeviceAuthorizer.sampleExternalForm.map { String(format: "%02x", $0) }.joined()
        #expect(hex.count == 64)
        await #expect(throws: DeviceOpenError.authopenFailed(status: 3, message: "-stdoutpipe -extauth -o 2 /dev/rdisk7|\(hex)")) {
            _ = try await AuthopenOpener(executable: script.path, authorizer: authorizer).openForReadWrite(bsdName: "disk7")
        }
        #expect(authorizer.requestedPaths == ["/dev/rdisk7"])
    }

    @Test func standInThatIgnoresStdinIsAnErrorNotACrash() async throws {
        // Closes stdin at once, so the parent's write may hit a pipe with no reader.
        let script = try StandIn("exec 0<&-; exit 5")
        for _ in 0..<20 {
            await #expect(throws: DeviceOpenError.authopenFailed(status: 5, message: "")) {
                _ = try await opener(script.path).openForReadWrite(bsdName: "disk4")
            }
        }
    }

    @Test func writingToAClosedInputPipeFailsWithEPIPEInsteadOfSIGPIPE() throws {
        // Deterministic version of the race above: without F_SETNOSIGPIPE this kills the test process.
        let pipe = try AuthopenOpener.makeInputPipe()
        close(pipe.read)
        defer { close(pipe.write) }
        #expect(AuthopenOpener.send(FakeDeviceAuthorizer.sampleExternalForm, to: pipe.write) == EPIPE)
        #expect(fcntl(pipe.write, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func authorizationIsReleasedOnceWhenTheOpenSucceeds() throws {
        let (url, fileFD) = try makeTempFile()
        defer {
            close(fileFD)
            unlink(url.path)
        }
        let authorizer = FakeDeviceAuthorizer()
        let fd = try AuthopenOpener.obtainDescriptor(executable: "unused", authorizer: authorizer, devicePath: "/dev/rdisk4") { _, arguments, input in
            // Still alive while authopen runs.
            #expect(authorizer.authorizations.first?.releaseCount == 0)
            #expect(arguments.contains("-extauth"))
            #expect(input == FakeDeviceAuthorizer.sampleExternalForm)
            return AuthopenOpener.Outcome(descriptor: dup(fileFD), termination: .exited(0), stderr: "")
        }
        defer { close(fd) }
        #expect(fd >= 0)
        #expect(authorizer.authorizations.map(\.releaseCount) == [1])
    }

    @Test(arguments: [
        "exit 1",                       // authopen failed
        "echo not-a-descriptor; exit 0", // exited without sending an fd
        "kill -9 $$",                   // killed
    ])
    func authorizationIsReleasedOnceWhenNoDescriptorArrives(_ body: String) async throws {
        let script = try StandIn(body)
        let authorizer = FakeDeviceAuthorizer()
        await #expect(throws: DeviceOpenError.self) {
            _ = try await AuthopenOpener(executable: script.path, authorizer: authorizer).openForReadWrite(bsdName: "disk4")
        }
        #expect(authorizer.authorizations.map(\.releaseCount) == [1])
    }

    @Test func authorizationIsReleasedOnceWhenTheSpawnFails() async throws {
        let authorizer = FakeDeviceAuthorizer()
        await #expect(throws: DeviceOpenError.posix(operation: "posix_spawn", code: ENOENT)) {
            _ = try await AuthopenOpener(executable: "/nonexistent/isosword/authopen", authorizer: authorizer)
                .openForReadWrite(bsdName: "disk4")
        }
        #expect(authorizer.authorizations.map(\.releaseCount) == [1])
    }

    @Test func eachOpenAuthorizesAfresh() async throws {
        let script = try StandIn("exit 1")
        let authorizer = FakeDeviceAuthorizer()
        let standIn = AuthopenOpener(executable: script.path, authorizer: authorizer)
        for _ in 0..<2 {
            await #expect(throws: DeviceOpenError.self) { _ = try await standIn.openForReadWrite(bsdName: "disk4") }
        }
        #expect(authorizer.authorizations.map(\.releaseCount) == [1, 1])
    }
}

private func opener(_ executable: String) -> AuthopenOpener {
    AuthopenOpener(executable: executable, authorizer: FakeDeviceAuthorizer())
}

/// An executable `/bin/sh` script in the temp directory, deleted on deinit.
private final class StandIn {
    let path: String

    init(_ body: String) throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-standin-\(UUID().uuidString).sh").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        guard chmod(path, 0o755) == 0 else { throw DeviceIOError.posix(operation: "chmod", code: errno) }
    }

    deinit { unlink(path) }
}
