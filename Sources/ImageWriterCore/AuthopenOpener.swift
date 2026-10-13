import Foundation
import os

/// Opens raw disks through `/usr/libexec/authopen`, which passes back an open
/// descriptor, so the app never runs as root. The app shows the admin prompt itself
/// (`DeviceAuthorizer`) and hands the authorization over with `-extauth`, so the
/// dialog names ISO Sword. Each call authorizes afresh and prompts again.
public struct AuthopenOpener: DeviceOpener {
    static let defaultExecutable = "/usr/libexec/authopen"
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "authopen")

    let executable: String
    let authorizer: any DeviceAuthorizer

    public init() {
        executable = Self.defaultExecutable
        authorizer = SecurityAuthorizer()
    }

    /// Tests substitute a stand-in script and a fake authorizer here; they never run
    /// the real authopen or show a dialog.
    init(executable: String, authorizer: any DeviceAuthorizer) {
        self.executable = executable
        self.authorizer = authorizer
    }

    /// Opens `/dev/r<bsdName>` with `O_RDWR`. Blocks a background thread, not the
    /// caller, while the password prompt is up. Cancellation is honoured only before
    /// the prompt appears; the prompt itself cannot be withdrawn.
    public func openForReadWrite(bsdName: String) async throws -> any OpenedDevice {
        guard BSDName.isWholeDisk(bsdName) else { throw DeviceOpenError.invalidDiskName(bsdName) }
        try Task.checkCancellation()
        let executable = executable
        let authorizer = authorizer
        let devicePath = "/dev/r\(bsdName)"
        let fd = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            // AuthorizationCreate blocks while the dialog is up, so it runs here too.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.obtainDescriptor(executable: executable, authorizer: authorizer, devicePath: devicePath)
                })
            }
        }
        do {
            return try RawDevice(fd: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    typealias Runner = (_ executable: String, _ arguments: [String], _ input: [UInt8]) throws -> Outcome

    /// `runner` is a seam for tests that need a descriptor to arrive, which a shell
    /// stand-in can't send.
    static func obtainDescriptor(
        executable: String,
        authorizer: any DeviceAuthorizer,
        devicePath: String,
        runner: Runner = run
    ) throws -> Int32 {
        // A failed or cancelled authorization never spawns authopen.
        let authorization = try authorizer.authorize(devicePath: devicePath)
        // authopen resolves the external form while it runs, so free it only afterwards.
        defer { authorization.release() }
        let outcome = try runner(
            executable,
            ["-stdoutpipe", "-extauth", "-o", String(O_RDWR), devicePath],
            authorization.externalForm
        )
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
    /// With `-extauth` the app shows the dialog, but the cancel text still matters if
    /// authopen finds the external authorization insufficient and shows its own.
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

    /// Spawns `executable` with stdin on a pipe carrying `input`, stdout on one end of an
    /// `AF_UNIX` socketpair (a pipe cannot carry `SCM_RIGHTS`) and stderr on a pipe,
    /// then waits for a descriptor or EOF. `posix_spawn` rather than `Process` gives
    /// exact control over which descriptors the child gets.
    static func run(executable: String, arguments: [String], input: [UInt8]) throws -> Outcome {
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
        let stdinPipe: (read: Int32, write: Int32)
        do {
            stdinPipe = try makeInputPipe()
        } catch {
            (sockets + errorPipe).forEach { Darwin.close($0) }
            throw error
        }
        let (parentSocket, childSocket) = (sockets[0], sockets[1])
        let (stderrRead, stderrWrite) = (errorPipe[0], errorPipe[1])
        var stdinWrite: Int32? = stdinPipe.write
        defer {
            Darwin.close(parentSocket)
            Darwin.close(stderrRead)
            if let stdinWrite { Darwin.close(stdinWrite) }
        }
        // Keeps processes spawned elsewhere in the app from inheriting our ends,
        // which would hold the socket open and stop recvmsg from seeing EOF.
        // (makeInputPipe already did this for the stdin pipe.)
        for fd in [parentSocket, childSocket, stderrRead, stderrWrite] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, STDIN_FILENO)
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
        Darwin.close(stdinPipe.read)
        Darwin.close(childSocket)
        Darwin.close(stderrWrite)
        guard spawnStatus == 0 else {
            throw DeviceOpenError.posix(operation: "posix_spawn", code: spawnStatus)
        }

        // 32 bytes is under PIPE_BUF, so this can't block. Closing the write end
        // afterwards gives authopen EOF after the external form.
        if let code = send(input, to: stdinPipe.write) {
            // Usually EPIPE: authopen exited before reading stdin. Its exit status and
            // stderr below say why, so carry on and map those.
            log.error("writing to authopen stdin failed with errno \(code)")
        }
        Darwin.close(stdinPipe.write)
        stdinWrite = nil

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

    /// A pipe for the child's stdin. Both ends are `FD_CLOEXEC` like the other parent
    /// ends. The write end has `F_SETNOSIGPIPE`: if authopen exits before reading,
    /// a plain write would raise SIGPIPE and kill the app; this way it fails with EPIPE.
    static func makeInputPipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw DeviceOpenError.posix(operation: "pipe", code: errno)
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        guard fcntl(fds[1], F_SETNOSIGPIPE, 1) == 0 else {
            let code = errno
            fds.forEach { Darwin.close($0) }
            throw DeviceOpenError.posix(operation: "fcntl(F_SETNOSIGPIPE)", code: code)
        }
        return (fds[0], fds[1])
    }

    /// Writes all of `bytes` to `fd`. Returns nil on success, or the errno that stopped it.
    static func send(_ bytes: [UInt8], to fd: Int32) -> Int32? {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base + sent, buffer.count - sent)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return errno
            }
            sent += count
        }
        return nil
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
