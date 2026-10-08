import Foundation

/// A zero-filled, `posix_memalign`-backed buffer for raw device I/O.
public final class AlignedBuffer {
    public let count: Int
    public let alignment: Int
    private let pointer: UnsafeMutableRawPointer

    /// `alignment` must be a power of two and a multiple of the pointer size.
    public init(count: Int, alignment: Int) throws {
        guard count > 0 else { throw DeviceIOError.posix(operation: "posix_memalign", code: EINVAL) }
        var raw: UnsafeMutableRawPointer?
        let status = posix_memalign(&raw, alignment, count)
        guard status == 0, let raw else { throw DeviceIOError.posix(operation: "posix_memalign", code: status) }
        memset(raw, 0, count)
        pointer = raw
        self.count = count
        self.alignment = alignment
    }

    /// A buffer aligned to both the page size and the device block size.
    public convenience init(count: Int, blockSize: Int) throws {
        try self.init(count: count, alignment: max(Int(getpagesize()), blockSize))
    }

    deinit { free(pointer) }

    public var bytes: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: pointer, count: count)
    }

    /// Zeroes `range`, e.g. the padding after a final partial block.
    public func zero(_ range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= count)
        memset(pointer + range.lowerBound, 0, range.count)
    }
}
