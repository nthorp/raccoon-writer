import Foundation

/// Receives a file descriptor passed with `SCM_RIGHTS` over an `AF_UNIX` socket,
/// which is how `authopen -stdoutpipe` hands back the opened device.
enum DescriptorReceiver {
    private static func align4(_ n: Int) -> Int { (n + 3) & ~3 }

    /// Reads until a message carries a descriptor. Returns nil if the peer closes
    /// the socket without sending one (authopen failed or was cancelled).
    static func receive(on socket: Int32) throws -> Int32? {
        let headerSize = align4(MemoryLayout<cmsghdr>.size)
        let controlSize = headerSize + align4(MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        // authopen sends 2 data bytes (00 00) with the descriptor; their content is unused.
        var data = [UInt8](repeating: 0, count: 64)

        while true {
            control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
            var controlLength = socklen_t(0)
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
                    return n
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw DeviceOpenError.posix(operation: "recvmsg", code: errno)
            }
            if Int(controlLength) >= headerSize + MemoryLayout<Int32>.size {
                let header = control.load(as: cmsghdr.self)
                if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                    return try closeOnExec(control.load(fromByteOffset: headerSize, as: Int32.self))
                }
            }
            if count == 0 { return nil }
        }
    }

    /// Descriptor flags don't travel with `SCM_RIGHTS`, and macOS has no
    /// `MSG_CMSG_CLOEXEC`, so the device arrives inheritable. A child spawned while it
    /// is open would get write access to the raw disk and could keep it busy past
    /// our close. If the flag can't be set, the descriptor is closed, failing closed.
    private static func closeOnExec(_ descriptor: Int32) throws -> Int32 {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw DeviceOpenError.posix(operation: "fcntl(FD_CLOEXEC)", code: code)
        }
        return descriptor
    }
}
