import Foundation

/// Copies an image onto an opened device in block-aligned chunks with throttled
/// progress, then flushes the device. Does not open, close, unmount or verify.
public struct WriteEngine: Sendable {
    public static let defaultChunkSize = 4 << 20

    /// Requested bytes per write. Rounded down to a multiple of the device block size, minimum one block.
    public let chunkSize: Int
    let clock: MonotonicClock

    public init(chunkSize: Int = defaultChunkSize, clock: MonotonicClock = .system) {
        self.chunkSize = max(1, chunkSize)
        self.clock = clock
    }

    /// Progress as a stream that finishes after the flush or throws the failure.
    /// Ending the iteration early or cancelling the consuming task cancels the write,
    /// but the in-flight chunk completes in the background; use the `onProgress`
    /// overload when the caller must know the device is idle before closing it.
    public func write(image: ImageInfo, to device: any OpenedDevice) -> AsyncThrowingStream<WriteProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await write(image: image, to: device) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes and flushes the image, calling `onProgress` on the I/O thread. Returns or
    /// throws only once the device is no longer in use. Cancellation is checked between
    /// chunks; a cancelled write throws `CancellationError` and never flushes.
    public func write(
        image: ImageInfo,
        to device: any OpenedDevice,
        onProgress: @escaping @Sendable (WriteProgress) -> Void
    ) async throws -> WriteResult {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            // Blocking I/O runs on GCD rather than tying up a cooperative-pool thread for minutes.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WriteResult, Error>) in
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

    /// The synchronous copy loop behind both public entry points.
    func run(
        image: ImageInfo,
        device: any OpenedDevice,
        isCancelled: () -> Bool,
        onProgress: (WriteProgress) -> Void
    ) throws -> WriteResult {
        if isCancelled() { throw CancellationError() }
        let total = image.sizeBytes
        guard total <= device.byteCount else {
            throw WriteEngineError.imageTooLarge(imageBytes: total, deviceBytes: device.byteCount)
        }
        let source = try ImageSource(image: image)
        let blockSize = device.blockSize
        let chunk = max(blockSize, chunkSize / blockSize * blockSize)
        let buffer = try AlignedBuffer(count: chunk, blockSize: blockSize)

        let start = clock.now()
        var meter = ProgressMeter(totalBytes: total, startTime: start)
        if let progress = meter.update(completedBytes: 0, at: start) { onProgress(progress) }

        try withExtendedLifetime(buffer) {
            var offset: UInt64 = 0
            while offset < total {
                if isCancelled() { throw CancellationError() }
                let length = Int(min(UInt64(chunk), total - offset))
                try source.readFully(into: UnsafeMutableRawBufferPointer(rebasing: buffer.bytes[..<length]), at: offset)
                let ioLength = BlockMath.roundUp(length, to: blockSize)
                // Only the final chunk can be partial; its padding must be zeros, not stale bytes.
                buffer.zero(length..<ioLength)
                try Self.writeFully(UnsafeRawBufferPointer(rebasing: buffer.bytes[..<ioLength]), to: device, at: offset)
                offset += UInt64(length)
                if let progress = meter.update(completedBytes: offset, at: clock.now()) { onProgress(progress) }
            }
        }

        // A cancel that lands after the last chunk must still not report a flushed drive.
        if isCancelled() { throw CancellationError() }
        let method: SyncMethod
        do {
            method = try device.fullSync()
        } catch let error as DeviceIOError {
            throw WriteEngineError.sync(error)
        }
        return WriteResult(bytesWritten: total, syncMethod: method, elapsedSeconds: clock.now() - start)
    }

    /// `OpenedDevice.write` may write less than asked, so retry the remainder. Only a
    /// whole number of blocks can be retried: the remainder of a partial block has an
    /// unaligned offset and buffer, which a raw device rejects with `EINVAL`.
    private static func writeFully(_ data: UnsafeRawBufferPointer, to device: any OpenedDevice, at offset: UInt64) throws {
        var done = 0
        while done < data.count {
            let position = offset + UInt64(done)
            let count: Int
            do {
                count = try device.write(from: UnsafeRawBufferPointer(rebasing: data[done...]), at: position)
            } catch let error as DeviceIOError {
                throw WriteEngineError.write(error)
            }
            guard count > 0 else { throw WriteEngineError.stalled(atOffset: position) }
            guard BlockMath.isAligned(count, to: device.blockSize) else {
                throw WriteEngineError.partialBlock(atOffset: position, byteCount: count)
            }
            done += count
        }
    }
}
