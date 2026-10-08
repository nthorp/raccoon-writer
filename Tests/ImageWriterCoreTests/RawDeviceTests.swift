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
        // A regular APFS file supports F_FULLFSYNC.
        #expect(try device.fullSync() == .fullFsync)

        device.close()
        device.close()
        #expect(throws: DeviceIOError.closed) { _ = try device.read(count: 512, at: 0) }
        #expect(throws: DeviceIOError.closed) { _ = try device.write([UInt8](repeating: 0, count: 512), at: 0) }
        #expect(throws: DeviceIOError.closed) { try device.fullSync() }
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
