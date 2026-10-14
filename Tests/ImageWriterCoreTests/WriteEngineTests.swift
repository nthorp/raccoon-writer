import Foundation
import Testing
@testable import ImageWriterCore

/// Each test gets its own temp directory, removed in `deinit`.
final class WriteEngineTests {
    static let chunkBlocks = 4
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func image(_ bytes: [UInt8]) throws -> ImageInfo {
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).img")
        try Data(bytes).write(to: url)
        return ImageInfo(
            url: url, fileName: url.lastPathComponent, sizeBytes: UInt64(bytes.count), kind: .img,
            hasMBR: false, hasGPT: false, isISO9660: false, bootWarning: nil
        )
    }

    func engine(blockSize: Int, clock: MonotonicClock = steppingClock(step: 0)) -> WriteEngine {
        WriteEngine(chunkSize: Self.chunkBlocks * blockSize, clock: clock)
    }

    /// Fills the device with 0xEE so padding and untouched areas are distinguishable from zeros.
    func dirtyDevice(blockSize: Int, blockCount: UInt64, faults: FileBackedDevice.Faults = .init()) throws -> FileBackedDevice {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: blockCount)
        let junk = [UInt8](repeating: 0xEE, count: Int(device.byteCount))
        #expect(try device.write(junk, at: 0) == junk.count)
        device.faults = faults
        return device
    }

    func run(_ engine: WriteEngine, _ image: ImageInfo, _ device: any OpenedDevice, cancelWhen: () -> Bool = { false }) throws -> (WriteResult, [WriteProgress]) {
        var progress: [WriteProgress] = []
        let result = try engine.run(image: image, device: device, isCancelled: cancelWhen) { progress.append($0) }
        return (result, progress)
    }

    // MARK: - Data on the device

    enum SizeCase: CaseIterable, Sendable {
        case exactChunks, blockMultiplePlusOne, chunkPlusOne, underOneBlock

        func bytes(blockSize: Int) -> Int {
            switch self {
            case .exactChunks: return 3 * WriteEngineTests.chunkBlocks * blockSize
            case .blockMultiplePlusOne: return 5 * blockSize + 1
            case .chunkPlusOne: return WriteEngineTests.chunkBlocks * blockSize + 1
            case .underOneBlock: return 100
            }
        }
    }

    @Test(arguments: [512, 4096], SizeCase.allCases)
    func deviceHoldsImageThenZeroPadding(blockSize: Int, sizeCase: SizeCase) throws {
        let size = sizeCase.bytes(blockSize: blockSize)
        let bytes = pattern(count: size)
        let device = try dirtyDevice(blockSize: blockSize, blockCount: 20)
        let (result, _) = try run(engine(blockSize: blockSize), image(bytes), device)

        let contents = Array(try device.contents())
        let padded = BlockMath.roundUp(size, to: blockSize)
        #expect(Array(contents[..<size]) == bytes)
        #expect(contents[size..<padded].allSatisfy { $0 == 0 })
        #expect(contents[padded...].allSatisfy { $0 == 0xEE })

        let chunk = Self.chunkBlocks * blockSize
        #expect(device.writeCallCount - 1 == (size + chunk - 1) / chunk)
        #expect(result.bytesWritten == UInt64(size))
        #expect(result.syncMethod == .fullFsync)
        #expect(device.syncCallCount == 1)
    }

    @Test func imageFillingTheWholeDevice() throws {
        let bytes = pattern(count: 8 * 512)
        let device = try dirtyDevice(blockSize: 512, blockCount: 8)
        _ = try run(engine(blockSize: 512), image(bytes), device)
        #expect(Array(try device.contents()) == bytes)
    }

    @Test func imageLargerThanDeviceWritesNothing() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8)
        #expect(throws: WriteEngineError.imageTooLarge(imageBytes: 4097, deviceBytes: 4096)) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 4097)), device)
        }
        #expect(device.writeCallCount == 0)
        #expect(device.syncCallCount == 0)
    }

    @Test(arguments: [(1000, 1), (100, 1), (4096, 8)])
    func chunkSizeRoundsDownToBlocks(chunkSize: Int, blocksPerWrite: Int) throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        let engine = WriteEngine(chunkSize: chunkSize, clock: steppingClock(step: 0))
        _ = try run(engine, image(pattern(count: 16 * 512)), device)
        #expect(device.writeCallCount == 16 / blocksPerWrite)
    }

    // MARK: - Device faults

    @Test(arguments: [512, 4096])
    func shortWriteIsRetried(_ blockSize: Int) throws {
        let bytes = pattern(count: 3 * Self.chunkBlocks * blockSize)
        let device = try dirtyDevice(blockSize: blockSize, blockCount: 16, faults: .init(shortWriteOnCall: 3))
        _ = try run(engine(blockSize: blockSize), image(bytes), device)
        #expect(Array(try device.contents()[..<bytes.count]) == bytes)
        // Prefill, then three chunks, one of which needed a second call.
        #expect(device.writeCallCount == 1 + 3 + 1)
    }

    @Test func writeFailureStopsWithoutSync() throws {
        let chunk = Self.chunkBlocks * 512
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16, faults: .init(failWrite: .init(call: 2, code: ENXIO)))
        #expect(throws: WriteEngineError.write(.posix(operation: "write at offset \(chunk)", code: ENXIO))) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 3 * chunk)), device)
        }
        #expect(device.writeCallCount == 2)
        #expect(device.syncCallCount == 0)
    }

    @Test func deviceAcceptingNothingIsAStall() throws {
        let device = ZeroWriteDevice()
        #expect(throws: WriteEngineError.stalled(atOffset: 0)) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 1024)), device)
        }
        #expect(device.syncCallCount == 0)
    }

    @Test func syncFailureFailsTheWrite() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16, faults: .init(syncError: EIO))
        #expect(throws: WriteEngineError.sync(.posix(operation: "F_FULLFSYNC", code: EIO))) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 4096)), device)
        }
    }

    @Test(arguments: [
        (FileBackedDevice.Faults(synchronizeSupported: true), SyncMethod.synchronize),
        (FileBackedDevice.Faults(), SyncMethod.fullFsync),
        (FileBackedDevice.Faults(fullFsyncUnsupported: true), SyncMethod.fsyncFallback),
    ])
    func reportsTheSyncMethodTheDeviceUsed(faults: FileBackedDevice.Faults, method: SyncMethod) throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16, faults: faults)
        let (result, _) = try run(engine(blockSize: 512), image(pattern(count: 4096)), device)
        #expect(result.syncMethod == method)
        #expect(device.lastSyncMethod == method)
    }

    @Test func imageChangedSinceSelectionWritesNothing() throws {
        var info = try image(pattern(count: 4096))
        info.sizeBytes += 1
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        #expect(throws: ImageSourceError.changed(fileName: info.fileName)) {
            _ = try self.run(self.engine(blockSize: 512), info, device)
        }
        #expect(device.writeCallCount == 0)
    }

    // MARK: - Cancellation

    @Test func cancelBetweenChunksStopsWithoutSync() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 64)
        #expect(throws: CancellationError.self) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 64 * 512)), device) {
                device.writeCallCount >= 2
            }
        }
        #expect(device.writeCallCount == 2)
        #expect(device.syncCallCount == 0)
        #expect(device.lastSyncMethod == nil)
    }

    @Test func cancelAfterLastChunkStillSkipsSync() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8)
        #expect(throws: CancellationError.self) {
            _ = try self.run(self.engine(blockSize: 512), self.image(pattern(count: 8 * 512)), device) {
                device.writeCallCount == 2
            }
        }
        #expect(device.syncCallCount == 0)
    }

    @Test func cancellingTheTaskStopsWithinOneChunk() async throws {
        let inner = try FileBackedDevice(blockSize: 512, blockCount: 64)
        let device = GatedDevice(inner: inner, gatedWrite: 2)
        let info = try image(pattern(count: 64 * 512))
        let engine = self.engine(blockSize: 512)
        let task = Task { try await engine.write(image: info, to: device) { _ in } }

        await device.gate.waitForArrival()
        task.cancel()
        device.gate.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(inner.writeCallCount == 2)
        #expect(inner.syncCallCount == 0)
        #expect(inner.lastSyncMethod == nil)
    }

    @Test func alreadyCancelledTaskTouchesNothing() async throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8)
        let info = try image(pattern(count: 4096))
        let engine = self.engine(blockSize: 512)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.write(image: info, to: device) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(device.writeCallCount == 0)
    }

    // MARK: - Progress and speed

    @Test func progressIsThrottledAndEndsAtTotal() throws {
        // 64 chunks, 10 ms apart: about one update per 10 chunks.
        let device = try FileBackedDevice(blockSize: 512, blockCount: 64)
        let engine = WriteEngine(chunkSize: 512, clock: steppingClock(step: 0.01))
        let (_, progress) = try run(engine, image(pattern(count: 64 * 512)), device)

        #expect(progress.first?.completedBytes == 0)
        #expect(progress.last?.completedBytes == 64 * 512)
        #expect(progress.allSatisfy { $0.totalBytes == 64 * 512 })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.completedBytes < $1.completedBytes })
        #expect((6...9).contains(progress.count))
    }

    @Test func frozenClockPublishesOnlyStartAndEnd() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 64)
        let (_, progress) = try run(engine(blockSize: 512), image(pattern(count: 64 * 512)), device)
        #expect(progress.map(\.completedBytes) == [0, 64 * 512])
    }

    @Test func speedAndElapsedFollowTheClock() throws {
        // Each chunk of 2 KiB "takes" 0.5 s, so the speed is 4 KiB/s.
        let device = try FileBackedDevice(blockSize: 512, blockCount: 64)
        let (result, progress) = try run(engine(blockSize: 512, clock: steppingClock(step: 0.5)), image(pattern(count: 32 * 512)), device)
        let last = try #require(progress.last)
        #expect(last.bytesPerSecond == 4096)
        #expect(last.estimatedSecondsRemaining == 0)
        let midway = try #require(progress.first { $0.completedBytes == 4 * 2048 })
        #expect(midway.estimatedSecondsRemaining == 2)
        // Start read, one read per chunk (8), one for the result.
        #expect(result.elapsedSeconds == 0.5 * 9)
    }

    // MARK: - Async entry points

    @Test func asyncWriteReportsProgressFromTheIOThread() async throws {
        let bytes = pattern(count: 10 * 512 + 7)
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        let recorder = Recorder<WriteProgress>()
        let result = try await engine(blockSize: 512).write(image: image(bytes), to: device) { recorder.append($0) }
        #expect(result.bytesWritten == UInt64(bytes.count))
        #expect(recorder.values.last?.completedBytes == UInt64(bytes.count))
        #expect(Array(try device.contents()[..<bytes.count]) == bytes)
    }

    @Test func streamYieldsProgressAndFinishes() async throws {
        let bytes = pattern(count: 9 * 512)
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        var updates: [WriteProgress] = []
        let stream = engine(blockSize: 512).write(image: try image(bytes), to: device)
        for try await progress in stream {
            updates.append(progress)
        }
        #expect(updates.map(\.completedBytes) == [0, UInt64(bytes.count)])
        #expect(device.syncCallCount == 1)
        #expect(Array(try device.contents()[..<bytes.count]) == bytes)
    }

    @Test func streamThrowsTheFailure() async throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 1)
        let stream = engine(blockSize: 512).write(image: try image(pattern(count: 513)), to: device)
        await #expect(throws: WriteEngineError.imageTooLarge(imageBytes: 513, deviceBytes: 512)) {
            for try await _ in stream {}
        }
    }

    @Test func cancellingTheStreamConsumerCancelsTheWrite() async throws {
        let inner = try FileBackedDevice(blockSize: 512, blockCount: 64)
        weak var weakDevice: GatedDevice?
        let info = try image(pattern(count: 64 * 512))
        let engine = self.engine(blockSize: 512)
        let gate: Gate
        let consumer: Task<Void, Error>
        do {
            let device = GatedDevice(inner: inner, gatedWrite: 2)
            weakDevice = device
            gate = device.gate
            consumer = Task { for try await _ in engine.write(image: info, to: device) {} }
        }

        await gate.waitForArrival()
        consumer.cancel()
        // The stream's termination handler has cancelled the write once the consumer has ended.
        _ = await consumer.result
        gate.release()

        // The worker releases the device when it stops.
        let deadline = Date().addingTimeInterval(5)
        while weakDevice != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakDevice == nil)
        #expect(inner.writeCallCount == 2)
        #expect(inner.syncCallCount == 0)
    }
}
