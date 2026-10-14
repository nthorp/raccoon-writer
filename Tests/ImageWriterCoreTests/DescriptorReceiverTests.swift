import Foundation
import Testing
@testable import ImageWriterCore

/// Exercises the SCM_RIGHTS receive path over a local socketpair, the way authopen sends.
struct DescriptorReceiverTests {
    @Test func receivesDescriptorSentWithData() throws {
        let (sender, receiver) = try makeSocketPair()
        defer {
            close(sender)
            close(receiver)
        }
        let (url, fileFD) = try makeTempFile()
        defer {
            close(fileFD)
            unlink(url.path)
        }

        try send(descriptor: fileFD, payload: [0, 0], on: sender)
        let received = try #require(try DescriptorReceiver.receive(on: receiver))
        defer { close(received) }

        // A new descriptor number referring to the same file.
        #expect(received != fileFD)
        var original = stat()
        var copy = stat()
        #expect(fstat(fileFD, &original) == 0)
        #expect(fstat(received, &copy) == 0)
        #expect(original.st_ino == copy.st_ino)
        #expect(original.st_dev == copy.st_dev)
    }

    @Test func receivedDescriptorIsCloseOnExec() throws {
        let (sender, receiver) = try makeSocketPair()
        defer {
            close(sender)
            close(receiver)
        }
        let (url, fileFD) = try makeTempFile()
        defer {
            close(fileFD)
            unlink(url.path)
        }

        try send(descriptor: fileFD, payload: [0, 0], on: sender)
        let received = try #require(try DescriptorReceiver.receive(on: receiver))
        defer { close(received) }

        // Descriptor flags don't travel with SCM_RIGHTS, so a child process spawned
        // while the device is open would otherwise inherit write access to it.
        let flags = fcntl(received, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
    }

    @Test func returnsNilWhenPeerClosesWithoutDescriptor() throws {
        let (sender, receiver) = try makeSocketPair()
        defer { close(receiver) }
        _ = [UInt8]([1, 2, 3]).withUnsafeBytes { Darwin.write(sender, $0.baseAddress, $0.count) }
        close(sender)
        #expect(try DescriptorReceiver.receive(on: receiver) == nil)
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw DeviceIOError.posix(operation: "socketpair", code: errno)
        }
        return (sockets[0], sockets[1])
    }

    private func send(descriptor: Int32, payload: [UInt8], on socket: Int32) throws {
        let headerSize = (MemoryLayout<cmsghdr>.size + 3) & ~3
        let controlSize = headerSize + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
        control.storeBytes(
            of: cmsghdr(cmsg_len: socklen_t(controlSize), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS),
            as: cmsghdr.self
        )
        control.storeBytes(of: descriptor, toByteOffset: headerSize, as: Int32.self)

        var data = payload
        let sent = data.withUnsafeMutableBytes { buffer in
            var iov = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &iov) { iovPointer in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlSize)
                return sendmsg(socket, &message, 0)
            }
        }
        guard sent == payload.count else { throw DeviceIOError.posix(operation: "sendmsg", code: errno) }
    }
}
