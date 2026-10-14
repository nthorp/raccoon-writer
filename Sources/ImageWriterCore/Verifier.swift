import Foundation

public typealias VerifyProgress = TransferProgress

/// Reads the image back from an opened device and compares it with the source file,
/// in block-aligned chunks with throttled progress. Never writes, flushes or closes.
public struct Verifier: Sendable {
    public static let defaultChunkSize = WriteEngine.defaultChunkSize

    /// Requested bytes per read. Rounded down to a multiple of the device block size, minimum one block.
    public let chunkSize: Int
    let clock: MonotonicClock

    public init(chunkSize: Int = defaultChunkSize, clock: MonotonicClock = .system) {
        self.chunkSize = max(1, chunkSize)
        self.clock = clock
    }

    /// Progress as a stream that finishes when every byte matched or throws the failure.
    /// Ending the iteration early or cancelling the consuming task cancels the verify,
    /// but the in-flight chunk completes in the background; use the `onProgress`
    /// overload when the caller must know the device is idle before closing it.
    public func verify(image: ImageInfo, against device: any OpenedDevice) -> AsyncThrowingStream<VerifyProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await verify(image: image, against: device) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Verifies the image, calling `onProgress` on the I/O thread. Returns or throws only
    /// once the device is no longer in use. Cancellation is checked between chunks.
    public func verify(
        image: ImageInfo,
        against device: any OpenedDevice,
        onProgress: @escaping @Sendable (VerifyProgress) -> Void
    ) async throws -> VerifyResult {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            // Blocking I/O runs on GCD rather than tying up a cooperative-pool thread for minutes.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VerifyResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try run(image: image, device: device, isCancelled: { flag.isCancelled }, onProgress: onProgress)
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// The synchronous compare loop behind both public entry points.
    func run(
        image: ImageInfo,
        device: any OpenedDevice,
        isCancelled: () -> Bool,
        onProgress: (VerifyProgress) -> Void
    ) throws -> VerifyResult {
        if isCancelled() { throw CancellationError() }
        let total = image.sizeBytes
        guard total <= device.byteCount else {
            throw VerifierError.imageTooLarge(imageBytes: total, deviceBytes: device.byteCount)
        }
        let source = try ImageSource(image: image)
        let blockSize = device.blockSize
        let chunk = max(blockSize, chunkSize / blockSize * blockSize)
        let expected = try AlignedBuffer(count: chunk, blockSize: blockSize)
        let actual = try AlignedBuffer(count: chunk, blockSize: blockSize)

        let start = clock.now()
        var meter = ProgressMeter(totalBytes: total, startTime: start)
        if let progress = meter.update(completedBytes: 0, at: start) { onProgress(progress) }

        try withExtendedLifetime((expected, actual)) {
            var offset: UInt64 = 0
            while offset < total {
                if isCancelled() { throw CancellationError() }
                let length = Int(min(UInt64(chunk), total - offset))
                try source.readFully(into: UnsafeMutableRawBufferPointer(rebasing: expected.bytes[..<length]), at: offset)
                // The device must be read in whole blocks, but the padding after the
                // image's last byte is not part of the image and is not compared.
                let ioLength = BlockMath.roundUp(length, to: blockSize)
                try Self.readFully(into: UnsafeMutableRawBufferPointer(rebasing: actual.bytes[..<ioLength]), from: device, at: offset)
                if let index = Self.firstMismatch(
                    UnsafeRawBufferPointer(rebasing: expected.bytes[..<length]),
                    UnsafeRawBufferPointer(rebasing: actual.bytes[..<length])
                ) {
                    throw VerifierError.verificationFailed(atOffset: offset + UInt64(index))
                }
                offset += UInt64(length)
                if let progress = meter.update(completedBytes: offset, at: clock.now()) { onProgress(progress) }
            }
        }
        // Bytes read early in the run may predate an in-place change; matching them
        // proves nothing about the file now on disk.
        try source.checkUnchanged()
        return VerifyResult(bytesVerified: total, elapsedSeconds: clock.now() - start)
    }

    /// `OpenedDevice.read` may return less than asked, so retry the remainder. Only a
    /// whole number of blocks can be retried: the remainder of a partial block has an
    /// unaligned offset and buffer, which a raw device rejects with `EINVAL`.
    private static func readFully(into buffer: UnsafeMutableRawBufferPointer, from device: any OpenedDevice, at offset: UInt64) throws {
        var filled = 0
        while filled < buffer.count {
            let position = offset + UInt64(filled)
            let count: Int
            do {
                count = try device.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]), at: position)
            } catch let error as DeviceIOError {
                throw VerifierError.read(error)
            }
            guard count > 0 else { throw VerifierError.deviceEnded(atOffset: position) }
            guard BlockMath.isAligned(count, to: device.blockSize) else {
                throw VerifierError.partialBlock(atOffset: position, byteCount: count)
            }
            filled += count
        }
    }

    /// Index of the first differing byte, or nil if the buffers are equal.
    static func firstMismatch(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Int? {
        precondition(lhs.count == rhs.count)
        // memcmp settles the common all-equal case quickly; only a mismatch needs the byte scan.
        guard let left = lhs.baseAddress, let right = rhs.baseAddress, memcmp(left, right, lhs.count) != 0 else {
            return nil
        }
        return lhs.indices.first { lhs[$0] != rhs[$0] }
    }
}
