import Foundation
import Testing
@testable import ImageWriterCore

struct FileBackedDeviceTests {
    @Test(arguments: [512, 4096])
    func geometryAndZeroFill(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16)
        #expect(device.byteCount == UInt64(16 * blockSize))
        let contents = try device.contents()
        #expect(contents.count == 16 * blockSize)
        #expect(contents.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [512, 4096])
    func alignedRoundTrip(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16)
        let bytes = pattern(count: 3 * blockSize)
        let offset = UInt64(2 * blockSize)
        #expect(try device.write(bytes, at: offset) == bytes.count)
        #expect(try device.read(count: bytes.count, at: offset) == bytes)
        let contents = try device.contents()
        #expect(Array(contents[2 * blockSize ..< 5 * blockSize]) == bytes)
        #expect(contents[..<(2 * blockSize)].allSatisfy { $0 == 0 })
    }

    @Test(arguments: [512, 4096])
    func unalignedRequestsFailWithEINVAL(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16)
        let block = [UInt8](repeating: 1, count: blockSize)
        #expect(posixCode { _ = try device.write(Array(block.prefix(100)), at: 0) } == EINVAL)
        #expect(posixCode { _ = try device.write(block + [1], at: 0) } == EINVAL)
        #expect(posixCode { _ = try device.write(block, at: 1) } == EINVAL)
        #expect(posixCode { _ = try device.write(block, at: UInt64(blockSize / 2)) } == EINVAL)
        #expect(posixCode { _ = try device.read(count: 100, at: 0) } == EINVAL)
        #expect(posixCode { _ = try device.read(count: blockSize, at: 1) } == EINVAL)
        #expect(try device.contents().allSatisfy { $0 == 0 })
    }

    @Test(arguments: [512, 4096])
    func endOfDevice(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 4)
        let end = device.byteCount
        let block = [UInt8](repeating: 7, count: blockSize)
        #expect(try device.read(count: blockSize, at: end).isEmpty)
        #expect(try device.read(count: 2 * blockSize, at: end - UInt64(blockSize)).count == blockSize)
        #expect(posixCode { _ = try device.write(block, at: end) } == ENOSPC)
        #expect(try device.write(block + block, at: end - UInt64(blockSize)) == blockSize)
        #expect(try device.contents().count == Int(end))
    }

    @Test(arguments: [512, 4096])
    func injectedWriteFailure(_ blockSize: Int) throws {
        let faults = FileBackedDevice.Faults(failWrite: .init(call: 2, code: ENXIO))
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 8, faults: faults)
        let block = [UInt8](repeating: 9, count: blockSize)
        #expect(try device.write(block, at: 0) == blockSize)
        #expect(posixCode { _ = try device.write(block, at: UInt64(blockSize)) } == ENXIO)
        #expect(try device.write(block, at: UInt64(blockSize)) == blockSize)
        #expect(device.writeCallCount == 3)
    }

    @Test func injectedReadFailure() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8, faults: .init(failRead: .init(call: 1)))
        #expect(posixCode { _ = try device.read(count: 512, at: 0) } == EIO)
        #expect(try device.read(count: 512, at: 0).count == 512)
    }

    @Test(arguments: [512, 4096])
    func injectedShortWrite(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16, faults: .init(shortWriteOnCall: 1))
        let bytes = pattern(count: 5 * blockSize)
        let written = try device.write(bytes, at: 0)
        #expect(written == 2 * blockSize)
        #expect(Array(try device.contents()[..<written]) == Array(bytes[..<written]))
        #expect(try device.contents()[written...].allSatisfy { $0 == 0 })
        // The remainder goes through normally on the retry.
        #expect(try device.write(Array(bytes[written...]), at: UInt64(written)) == bytes.count - written)
        #expect(Array(try device.contents()[..<bytes.count]) == bytes)
    }

    @Test func shortWriteOfSingleBlockIsComplete() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 4, faults: .init(shortWriteOnCall: 1))
        #expect(try device.write([UInt8](repeating: 1, count: 512), at: 0) == 512)
    }

    @Test func syncPaths() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 4)
        #expect(device.lastSyncMethod == nil)
        #expect(try device.fullSync() == .fullFsync)
        #expect(device.lastSyncMethod == .fullFsync)

        device.faults.fullFsyncUnsupported = true
        #expect(try device.fullSync() == .fsyncFallback)
        #expect(device.lastSyncMethod == .fsyncFallback)

        device.faults = .init(syncError: EIO)
        #expect(throws: DeviceIOError.posix(operation: "F_FULLFSYNC", code: EIO)) { try device.fullSync() }
        device.faults = .init(syncError: EIO, fullFsyncUnsupported: true)
        #expect(throws: DeviceIOError.posix(operation: "fsync", code: EIO)) { try device.fullSync() }
        #expect(device.lastSyncMethod == .fsyncFallback)
        #expect(device.syncCallCount == 4)
    }

    @Test func closeIsIdempotentAndBlocksFurtherIO() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 4)
        _ = try device.write([UInt8](repeating: 3, count: 512), at: 0)
        device.close()
        device.close()
        #expect(device.isClosed)
        #expect(device.closeCallCount == 2)
        #expect(throws: DeviceIOError.closed) { _ = try device.read(count: 512, at: 0) }
        #expect(throws: DeviceIOError.closed) { _ = try device.write([UInt8](repeating: 0, count: 512), at: 0) }
        #expect(throws: DeviceIOError.closed) { try device.fullSync() }
        #expect(try device.contents().prefix(512).allSatisfy { $0 == 3 })
    }

    @Test func backingFileRemovedOnDeinit() throws {
        var device: FileBackedDevice? = try FileBackedDevice(blockSize: 512, blockCount: 1)
        let path = try #require(device?.url.path)
        #expect(FileManager.default.fileExists(atPath: path))
        device = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func rejectsInvalidGeometry() {
        #expect(throws: DeviceIOError.invalidGeometry(blockSize: 1000, blockCount: 4)) {
            _ = try FileBackedDevice(blockSize: 1000, blockCount: 4)
        }
    }
}
