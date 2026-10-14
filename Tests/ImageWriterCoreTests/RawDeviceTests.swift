import Foundation
import Testing
@testable import ImageWriterCore

/// Drives `RawDevice` over a regular temp file; no real disk is involved.
struct RawDeviceTests {
    @Test func readWriteSyncAndClose() throws {
        let (url, fd) = try makeTempFile()
        defer { unlink(url.path) }
        let device = try RawDevice(fd: fd, blockSize: 512, blockCount: 8)
        #expect(device.byteCount == 4096)

        let bytes = pattern(count: 1024)
        #expect(try device.write(bytes, at: 512) == 1024)
        #expect(try device.read(count: 1024, at: 512) == bytes)
        // A regular file returns ENOTTY for DKIOCSYNCHRONIZE, and APFS supports F_FULLFSYNC.
        #expect(try device.fullSync() == .fullFsync)

        device.close()
        device.close()
        #expect(throws: DeviceIOError.closed) { _ = try device.read(count: 512, at: 0) }
        #expect(throws: DeviceIOError.closed) { _ = try device.write([UInt8](repeating: 0, count: 512), at: 0) }
        #expect(throws: DeviceIOError.closed) { try device.fullSync() }
    }

    @Test func synchronizeIoctlMatchesTheHeader() {
        // _IOW(g, n, t) = IOC_IN | (sizeof(t) & IOCPARM_MASK) << 16 | g << 8 | n, from <sys/ioccom.h>.
        let size = UInt(MemoryLayout<dk_synchronize_t>.size)
        #expect(size == 24)
        let expected = UInt(0x8000_0000) | (size & 0x1FFF) << 16 | UInt(UInt8(ascii: "d")) << 8 | 22
        #expect(RawDevice.ioctlSynchronize == expected)
        #expect(RawDevice.ioctlSynchronize == 0x8018_6416)
    }

    @Test func rejectsInvalidGeometry() throws {
        let (url, fd) = try makeTempFile()
        defer {
            close(fd)
            unlink(url.path)
        }
        #expect(throws: DeviceIOError.invalidGeometry(blockSize: 1000, blockCount: 8)) {
            _ = try RawDevice(fd: fd, blockSize: 1000, blockCount: 8)
        }
        #expect(throws: DeviceIOError.invalidGeometry(blockSize: 512, blockCount: 0)) {
            _ = try RawDevice(fd: fd, blockSize: 512, blockCount: 0)
        }
    }

    @Test func geometryIoctlFailsOnRegularFileAndLeavesDescriptorOpen() throws {
        let (url, fd) = try makeTempFile()
        defer {
            close(fd)
            unlink(url.path)
        }
        #expect(posixCode { _ = try RawDevice(fd: fd) } == ENOTTY)
        #expect(fcntl(fd, F_GETFD) != -1)
    }
}
