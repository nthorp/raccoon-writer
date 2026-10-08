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
    }

    // MARK: - Spawning a stand-in

    @Test func invalidNameThrowsBeforeSpawning() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-marker-\(UUID().uuidString)")
        let script = try StandIn("touch '\(marker.path)'; exit 1")
        let opener = AuthopenOpener(executable: script.path)
        for name in ["disk4s1", "/dev/disk4", "disk4;rm", "rdisk4", ""] {
            await #expect(throws: DeviceOpenError.invalidDiskName(name)) {
                _ = try await opener.openForReadWrite(bsdName: name)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func passesExactArguments() async throws {
        let script = try StandIn("echo \"$@\" >&2; exit 3")
        await #expect(throws: DeviceOpenError.authopenFailed(status: 3, message: "-stdoutpipe -o 2 /dev/rdisk42")) {
            _ = try await AuthopenOpener(executable: script.path).openForReadWrite(bsdName: "disk42")
        }
    }

    @Test func cancelFromStandInMapsToUserCancelled() async throws {
        let script = try StandIn("echo 'AuthorizationCreate failed: The authorization was canceled by the user.' >&2; exit 1")
        await #expect(throws: DeviceOpenError.userCancelled) {
            _ = try await AuthopenOpener(executable: script.path).openForReadWrite(bsdName: "disk4")
        }
    }

    @Test func cleanExitWithoutDescriptorFails() async throws {
        let script = try StandIn("echo not-a-descriptor; exit 0")
        await #expect(throws: DeviceOpenError.authopenFailed(status: 0, message: "")) {
            _ = try await AuthopenOpener(executable: script.path).openForReadWrite(bsdName: "disk4")
        }
    }

    @Test func killedStandInIsTermination() async throws {
        let script = try StandIn("kill -9 $$")
        await #expect(throws: DeviceOpenError.authopenTerminated(signal: 9)) {
            _ = try await AuthopenOpener(executable: script.path).openForReadWrite(bsdName: "disk4")
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
            _ = try await AuthopenOpener(executable: script.path).openForReadWrite(bsdName: "disk4")
            Issue.record("expected a failure")
        } catch DeviceOpenError.authopenFailed(let status, let message) {
            #expect(status == 4)
            #expect(message != String(info.st_ino))
        }
    }

    @Test func missingExecutableIsSpawnError() async {
        await #expect(throws: DeviceOpenError.posix(operation: "posix_spawn", code: ENOENT)) {
            _ = try await AuthopenOpener(executable: "/nonexistent/isosword/authopen").openForReadWrite(bsdName: "disk4")
        }
    }
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
