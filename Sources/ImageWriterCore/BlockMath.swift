import Foundation

/// Arithmetic for block-multiple I/O sizes and offsets.
public enum BlockMath {
    public static func isAligned(_ value: UInt64, to blockSize: Int) -> Bool {
        blockSize > 0 && value % UInt64(blockSize) == 0
    }

    public static func isAligned(_ value: Int, to blockSize: Int) -> Bool {
        blockSize > 0 && value >= 0 && value % blockSize == 0
    }

    /// A usable device geometry: power-of-two block size, at least one block, byte count fits in UInt64.
    public static func isValidGeometry(blockSize: Int, blockCount: UInt64) -> Bool {
        let isPowerOfTwo = blockSize > 0 && blockSize & (blockSize - 1) == 0
        return isPowerOfTwo && blockCount > 0
            && !blockCount.multipliedReportingOverflow(by: UInt64(blockSize)).overflow
    }

    /// Smallest multiple of `blockSize` that is >= `value`.
    public static func roundUp(_ value: Int, to blockSize: Int) -> Int {
        precondition(blockSize > 0 && value >= 0)
        return (value + blockSize - 1) / blockSize * blockSize
    }
}
