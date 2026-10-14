import Foundation
import Testing
@testable import ImageWriterCore

/// Each test gets its own temp directory, removed in `deinit`.
final class VerifierTests {
    static let chunkBlocks = 4
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-verify-\(UUID().uuidString)")
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

    func verifier(blockSize: Int, clock: MonotonicClock = steppingClock(step: 0)) -> Verifier {
        Verifier(chunkSize: Self.chunkBlocks * blockSize, clock: clock)
    }

    /// A device holding `bytes` followed by 0xEE to the end, so the final block's
    /// padding is not zeros and must be ignored. `flip` inverts one byte first.
    func device(
        holding bytes: [UInt8],
        blockSize: Int,
        blockCount: UInt64,
        flip: Int? = nil,
        faults: FileBackedDevice.Faults = .init()
    ) throws -> FileBackedDevice {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: blockCount)
        var contents = bytes + [UInt8](repeating: 0xEE, count: Int(device.byteCount) - bytes.count)
        if let flip { contents[flip] ^= 0xFF }
        #expect(try device.write(contents, at: 0) == contents.count)
        device.faults = faults
        return device
    }

    func run(_ verifier: Verifier, _ image: ImageInfo, _ device: any OpenedDevice, cancelWhen: () -> Bool = { false }) throws -> (VerifyResult, [VerifyProgress]) {
        var progress: [VerifyProgress] = []
        let result = try verifier.run(image: image, device: device, isCancelled: cancelWhen) { progress.append($0) }
        return (result, progress)
    }

    // MARK: - Matching and mismatching data

    enum SizeCase: CaseIterable, Sendable {
        case exactChunks, blockMultiplePlusOne, chunkPlusOne, underOneBlock

        func bytes(blockSize: Int) -> Int {
            switch self {
            case .exactChunks: return 3 * VerifierTests.chunkBlocks * blockSize
            case .blockMultiplePlusOne: return 5 * blockSize + 1
            case .chunkPlusOne: return VerifierTests.chunkBlocks * blockSize + 1
            case .underOneBlock: return 100
            }
        }
    }

    @Test(arguments: [512, 4096], SizeCase.allCases)
    func matchingDataPassesDespiteNonzeroPadding(blockSize: Int, sizeCase: SizeCase) throws {
        let size = sizeCase.bytes(blockSize: blockSize)
        let bytes = pattern(count: size)
        let device = try device(holding: bytes, blockSize: blockSize, blockCount: 20)
        let (result, _) = try run(verifier(blockSize: blockSize), image(bytes), device)

        #expect(result.bytesVerified == UInt64(size))
        let chunk = Self.chunkBlocks * blockSize
        #expect(device.readCallCount == (size + chunk - 1) / chunk)
        // Only the setup write; verifying never writes or flushes.
        #expect(device.writeCallCount == 1)
        #expect(device.syncCallCount == 0)
    }

    enum FlipPosition: CaseIterable, Sendable {
        case first, middle, last
    }

    @Test(arguments: [512, 4096], FlipPosition.allCases)
    func flippedByteIsReportedAtItsOffset(blockSize: Int, position: FlipPosition) throws {
        // Three chunks, the last ending mid-block.
        let chunk = Self.chunkBlocks * blockSize
        let size = 3 * chunk - 100
        let offset: Int
        switch position {
        case .first: offset = 0
        case .middle: offset = size / 2
        case .last: offset = size - 1
        }
        let bytes = pattern(count: size)
        let device = try device(holding: bytes, blockSize: blockSize, blockCount: 16, flip: offset)

        #expect(throws: VerifierError.verificationFailed(atOffset: UInt64(offset))) {
            _ = try self.run(self.verifier(blockSize: blockSize), self.image(bytes), device)
        }
        // Stops at the chunk holding the bad byte.
        #expect(device.readCallCount == offset / chunk + 1)
    }

    @Test(arguments: [512, 4096])
    func writtenImageVerifies(_ blockSize: Int) async throws {
        let bytes = pattern(count: 7 * blockSize + 3)
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16)
        let info = try image(bytes)
        let chunk = Self.chunkBlocks * blockSize
        _ = try await WriteEngine(chunkSize: chunk).write(image: info, to: device) { _ in }
        let result = try await Verifier(chunkSize: chunk).verify(image: info, against: device) { _ in }
        #expect(result.bytesVerified == UInt64(bytes.count))
    }

    @Test func firstMismatchFindsTheFirstDifference() {
        let a: [UInt8] = [1, 2, 3, 4, 5]
        let b: [UInt8] = [1, 2, 9, 4, 0]
        a.withUnsafeBytes { a in
            b.withUnsafeBytes { b in
                #expect(Verifier.firstMismatch(a, b) == 2)
                #expect(Verifier.firstMismatch(a, a) == nil)
                #expect(Verifier.firstMismatch(UnsafeRawBufferPointer(rebasing: a[..<2]), UnsafeRawBufferPointer(rebasing: b[..<2])) == nil)
                #expect(Verifier.firstMismatch(UnsafeRawBufferPointer(rebasing: a[..<0]), UnsafeRawBufferPointer(rebasing: b[..<0])) == nil)
            }
        }
    }

    // MARK: - Device and image faults

    @Test(arguments: [512, 4096])
    func shortReadIsRetried(_ blockSize: Int) throws {
        let bytes = pattern(count: 3 * Self.chunkBlocks * blockSize)
        let device = try device(holding: bytes, blockSize: blockSize, blockCount: 16, faults: .init(shortReadOnCall: 2))
        _ = try run(verifier(blockSize: blockSize), image(bytes), device)
        // Three chunks, one of which needed a second call.
        #expect(device.readCallCount == 3 + 1)
    }

    @Test func readFailureIsReported() throws {
        let chunk = Self.chunkBlocks * 512
        let bytes = pattern(count: 3 * chunk)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 16, faults: .init(failRead: .init(call: 2, code: ENXIO)))
        #expect(throws: VerifierError.read(.posix(operation: "read at offset \(chunk)", code: ENXIO))) {
            _ = try self.run(self.verifier(blockSize: 512), self.image(bytes), device)
        }
        #expect(device.readCallCount == 2)
    }

    @Test func deviceReturningNothingHasEnded() throws {
        let device = ZeroWriteDevice()
        #expect(throws: VerifierError.deviceEnded(atOffset: 0)) {
            _ = try self.run(self.verifier(blockSize: 512), self.image(pattern(count: 1024)), device)
        }
    }

    @Test func imageLargerThanDeviceReadsNothing() throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8)
        #expect(throws: VerifierError.imageTooLarge(imageBytes: 4097, deviceBytes: 4096)) {
            _ = try self.run(self.verifier(blockSize: 512), self.image(pattern(count: 4097)), device)
        }
        #expect(device.readCallCount == 0)
    }

    @Test func imageChangedSinceSelectionReadsNothing() throws {
        var info = try image(pattern(count: 4096))
        info.sizeBytes -= 1
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        #expect(throws: ImageSourceError.changed(fileName: info.fileName)) {
            _ = try self.run(self.verifier(blockSize: 512), info, device)
        }
        #expect(device.readCallCount == 0)
    }

    // MARK: - Cancellation

    @Test func cancelBetweenChunksStops() throws {
        let bytes = pattern(count: 64 * 512)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 64)
        #expect(throws: CancellationError.self) {
            _ = try self.run(self.verifier(blockSize: 512), self.image(bytes), device) {
                device.readCallCount >= 2
            }
        }
        #expect(device.readCallCount == 2)
    }

    @Test func cancellingTheTaskStopsWithinOneChunk() async throws {
        let bytes = pattern(count: 64 * 512)
        let inner = try device(holding: bytes, blockSize: 512, blockCount: 64)
        let device = GatedDevice(inner: inner, gatedRead: 2)
        let info = try image(bytes)
        let verifier = self.verifier(blockSize: 512)
        let task = Task { try await verifier.verify(image: info, against: device) { _ in } }

        await device.gate.waitForArrival()
        task.cancel()
        device.gate.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(inner.readCallCount == 2)
    }

    @Test func alreadyCancelledTaskReadsNothing() async throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 8)
        let info = try image(pattern(count: 4096))
        let verifier = self.verifier(blockSize: 512)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await verifier.verify(image: info, against: device) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(device.readCallCount == 0)
    }

    @Test func cancellingTheStreamConsumerCancelsTheVerify() async throws {
        let bytes = pattern(count: 64 * 512)
        let inner = try device(holding: bytes, blockSize: 512, blockCount: 64)
        let device = GatedDevice(inner: inner, gatedRead: 2)
        let info = try image(bytes)
        let verifier = self.verifier(blockSize: 512)
        let consumer = Task { for try await _ in verifier.verify(image: info, against: device) {} }

        await device.gate.waitForArrival()
        consumer.cancel()
        _ = await consumer.result
        device.gate.release()

        // The worker sees the cancel before its next chunk.
        let deadline = Date().addingTimeInterval(5)
        var lastCount = -1
        while inner.readCallCount != lastCount, Date() < deadline {
            lastCount = inner.readCallCount
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inner.readCallCount == 2)
    }

    // MARK: - Progress

    @Test func progressIsThrottledAndEndsAtTotal() throws {
        // 64 chunks, 10 ms apart: about one update per 10 chunks.
        let bytes = pattern(count: 64 * 512)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 64)
        let verifier = Verifier(chunkSize: 512, clock: steppingClock(step: 0.01))
        let (_, progress) = try run(verifier, image(bytes), device)

        #expect(progress.first?.completedBytes == 0)
        #expect(progress.last?.completedBytes == 64 * 512)
        #expect(progress.allSatisfy { $0.totalBytes == 64 * 512 })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.completedBytes < $1.completedBytes })
        #expect((6...9).contains(progress.count))
    }

    @Test func speedAndElapsedFollowTheClock() throws {
        // Each chunk of 2 KiB "takes" 0.5 s, so the speed is 4 KiB/s.
        let bytes = pattern(count: 32 * 512)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 64)
        let (result, progress) = try run(verifier(blockSize: 512, clock: steppingClock(step: 0.5)), image(bytes), device)
        let last = try #require(progress.last)
        #expect(last.bytesPerSecond == 4096)
        #expect(last.estimatedSecondsRemaining == 0)
        // Start read, one read per chunk (8), one for the result.
        #expect(result.elapsedSeconds == 0.5 * 9)
    }

    @Test func streamYieldsProgressAndFinishes() async throws {
        let bytes = pattern(count: 9 * 512)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 16)
        var updates: [VerifyProgress] = []
        for try await progress in verifier(blockSize: 512).verify(image: try image(bytes), against: device) {
            updates.append(progress)
        }
        #expect(updates.map(\.completedBytes) == [0, UInt64(bytes.count)])
    }

    @Test func streamThrowsTheMismatch() async throws {
        let bytes = pattern(count: 9 * 512)
        let device = try device(holding: bytes, blockSize: 512, blockCount: 16, flip: 3000)
        let stream = verifier(blockSize: 512).verify(image: try image(bytes), against: device)
        await #expect(throws: VerifierError.verificationFailed(atOffset: 3000)) {
            for try await _ in stream {}
        }
    }
}
