import Foundation
import os

/// Opens raw disks through `/usr/libexec/authopen`, which shows the system admin
/// prompt and passes back an open descriptor, so the app never runs as root.
/// Each call is a fresh authopen process and prompts again (T01: no credential caching).
public struct AuthopenOpener: DeviceOpener {
    static let defaultExecutable = "/usr/libexec/authopen"
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "authopen")

    let executable: String

    public init() {
        executable = Self.defaultExecutable
    }

    /// Tests substitute a stand-in script here; they never run the real authopen.
    init(executable: String) {
        self.executable = executable
    }

    /// Opens `/dev/r<bsdName>` with `O_RDWR`. Blocks a background thread, not the
    /// caller, while the password prompt is up. Cancellation is honoured only before
    /// the prompt appears; the prompt itself cannot be withdrawn.
    public func openForReadWrite(bsdName: String) async throws -> any OpenedDevice {
        guard BSDName.isWholeDisk(bsdName) else { throw DeviceOpenError.invalidDiskName(bsdName) }
        try Task.checkCancellation()
        let executable = executable
        let devicePath = "/dev/r\(bsdName)"
        let fd = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.obtainDescriptor(executable: executable, devicePath: devicePath) })
            }
        }
        do {
            return try RawDevice(fd: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func obtainDescriptor(executable: String, devicePath: String) throws -> Int32 {
        let outcome = try run(executable: executable, arguments: ["-stdoutpipe", "-o", String(O_RDWR), devicePath])
        if let fd = outcome.descriptor, outcome.termination == .exited(0) {
            return fd
        }
        if let fd = outcome.descriptor {
            Darwin.close(fd)
        }
        log.error("authopen \(String(describing: outcome.termination), privacy: .public): \(outcome.stderr, privacy: .public)")
        throw failure(for: outcome.termination, stderr: outcome.stderr)
    }

    // MARK: - Error mapping

    enum Termination: Equatable {
        case exited(Int32)
        case signalled(Int32)

        /// Decodes a `waitpid` status by hand; Swift has no `WIFEXITED` family.
        init(waitStatus: Int32) {
            let signal = waitStatus & 0x7f
            self = signal == 0 ? .exited((waitStatus >> 8) & 0xff) : .signalled(signal)
        }
    }

    /// authopen exits 1 for every failure, so only its stderr text tells them apart.
    /// T01 observed the cancel text: "AuthorizationCreate failed: The authorization was canceled by the user."
    static func failure(for termination: Termination, stderr: String) -> DeviceOpenError {
        let text = stderr.lowercased()
        if text.contains("canceled by the user") || text.contains("cancelled by the user") {
            return .userCancelled
        }
        switch termination {
        case .signalled(let signal):
            return .authopenTerminated(signal: signal)
        case .exited(let status):
            if text.contains("busy") { return .deviceBusy }
            if text.contains("not permitted") || text.contains("denied") { return .permissionDenied }
            return .authopenFailed(status: status, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Process plumbing

    struct Outcome {
        var descriptor: Int32?
        var termination: Termination
        var stderr: String
    }

    /// Spawns `executable` with stdout on one end of an `AF_UNIX` socketpair (a pipe
    /// cannot carry `SCM_RIGHTS`) and stderr on a pipe, then waits for a descriptor or EOF.
    /// `posix_spawn` rather than `Process` gives exact control over which descriptors the child gets.
    static func run(executable: String, arguments: [String]) throws -> Outcome {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw DeviceOpenError.posix(operation: "socketpair", code: errno)
        }
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&errorPipe) == 0 else {
            let code = errno
            sockets.forEach { Darwin.close($0) }
            throw DeviceOpenError.posix(operation: "pipe", code: code)
        }
        let (parentSocket, childSocket) = (sockets[0], sockets[1])
        let (stderrRead, stderrWrite) = (errorPipe[0], errorPipe[1])
        defer {
            Darwin.close(parentSocket)
            Darwin.close(stderrRead)
        }
        // Keeps processes spawned elsewhere in the app from inheriting our ends,
        // which would hold the socket open and stop recvmsg from seeing EOF.
        for fd in [parentSocket, childSocket, stderrRead, stderrWrite] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, childSocket, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors set up above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        // Close our copies of the child's ends so we see EOF when it exits.
        Darwin.close(childSocket)
        Darwin.close(stderrWrite)
        guard spawnStatus == 0 else {
            throw DeviceOpenError.posix(operation: "posix_spawn", code: spawnStatus)
        }

        let descriptor: Int32?
        do {
            descriptor = try DescriptorReceiver.receive(on: parentSocket)
        } catch {
            _ = waitFor(pid)
            throw error
        }
        let stderr = readAll(stderrRead)
        return Outcome(descriptor: descriptor, termination: Termination(waitStatus: waitFor(pid)), stderr: stderr)
    }

    private static func waitFor(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }

    /// Drains `fd` to EOF, keeping the first 8 KiB; authopen's messages are one line.
    private static func readAll(_ fd: Int32) -> String {
        let limit = 8192
        var kept: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                log.error("reading authopen stderr failed with errno \(errno)")
                break
            }
            if kept.count < limit {
                kept += chunk.prefix(min(count, limit - kept.count))
            }
        }
        return String(decoding: kept, as: UTF8.self)
    }
}
