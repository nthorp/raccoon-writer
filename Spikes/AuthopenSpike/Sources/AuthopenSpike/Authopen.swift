import Foundation

let authopenPath = "/usr/libexec/authopen"

struct AuthopenResult {
    var fd: Int32
    var payload: [UInt8]
    var exitStatus: Int32
    var secondsWaiting: Double
}

private func align4(_ n: Int) -> Int { (n + 3) & ~3 }

/// Spawns `authopen -stdoutpipe -o <flags> <path>` with stdout on one end of a
/// Unix socketpair and receives the fd via SCM_RIGHTS on the other end.
/// SCM_RIGHTS needs an AF_UNIX socket, so a plain pipe(2) would not work.
func authopen(path: String, openFlags: Int32) throws -> AuthopenResult {
    var sockets: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
        throw SpikeError.posix("socketpair", errno: errno)
    }
    let parentEnd = sockets[0]
    let childEnd = sockets[1]
    defer { close(parentEnd) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, childEnd, STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, parentEnd)
    posix_spawn_file_actions_addclose(&actions, childEnd)

    let arguments = [authopenPath, "-stdoutpipe", "-o", String(openFlags), path]
    print("  spawning: \(arguments.joined(separator: " "))")
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }

    let start = Date()
    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, authopenPath, &actions, nil, &argv, environ)
    // Close our copy of the child's end so recvmsg sees EOF if authopen dies.
    close(childEnd)
    guard spawnStatus == 0 else { throw SpikeError.posix("posix_spawn", errno: spawnStatus) }

    let received: (fd: Int32, payload: [UInt8])
    do {
        received = try receiveDescriptor(on: parentEnd)
    } catch SpikeError.noDescriptorReceived {
        // The interesting case (cancel, denied, busy): report authopen's exit code.
        let status = waitFor(pid)
        if status & 0x7f != 0 { throw SpikeError.authopenSignalled(signal: status & 0x7f) }
        throw SpikeError.authopenExited(status: (status >> 8) & 0xff)
    } catch {
        _ = waitFor(pid)
        throw error
    }
    let status = waitFor(pid)
    let elapsed = Date().timeIntervalSince(start)

    if status & 0x7f != 0 { throw SpikeError.authopenSignalled(signal: status & 0x7f) }
    return AuthopenResult(
        fd: received.fd,
        payload: received.payload,
        exitStatus: (status >> 8) & 0xff,
        secondsWaiting: elapsed
    )
}

/// Returns the raw wait status (decode manually: Swift has no WIFEXITED macros).
private func waitFor(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    return status
}

/// Reads messages until one carries an SCM_RIGHTS descriptor. Records any data
/// bytes that arrive with it so the spike can report what authopen sends.
func receiveDescriptor(on socket: Int32) throws -> (fd: Int32, payload: [UInt8]) {
    let headerSize = align4(MemoryLayout<cmsghdr>.size)
    let controlSize = headerSize + align4(MemoryLayout<Int32>.size)
    let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { control.deallocate() }
    var data = [UInt8](repeating: 0, count: 256)
    var payload: [UInt8] = []

    while true {
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
        var controlLength = socklen_t(0)
        var flags: Int32 = 0
        let count: Int = data.withUnsafeMutableBytes { buffer in
            var iov = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &iov) { iovPointer in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlSize)
                let n = recvmsg(socket, &message, 0)
                controlLength = message.msg_controllen
                flags = message.msg_flags
                return n
            }
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw SpikeError.posix("recvmsg", errno: errno)
        }
        if count == 0 && controlLength == 0 {
            throw SpikeError.noDescriptorReceived
        }
        payload += data.prefix(count)
        if flags & MSG_CTRUNC != 0 {
            print("  warning: control message truncated (MSG_CTRUNC)")
        }
        if Int(controlLength) >= headerSize + MemoryLayout<Int32>.size {
            let header = control.load(as: cmsghdr.self)
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                let fd = control.load(fromByteOffset: headerSize, as: Int32.self)
                return (fd, payload)
            }
            print("  ignoring control message level \(header.cmsg_level) type \(header.cmsg_type)")
        }
    }
}
