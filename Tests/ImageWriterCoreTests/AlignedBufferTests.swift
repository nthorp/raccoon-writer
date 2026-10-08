import Foundation
import Testing
@testable import ImageWriterCore

struct AlignedBufferTests {
    @Test(arguments: [512, 4096, 16384])
    func alignedAndZeroed(_ alignment: Int) throws {
        let buffer = try AlignedBuffer(count: 3 * alignment, alignment: alignment)
        let address = Int(bitPattern: buffer.bytes.baseAddress)
        #expect(address % alignment == 0)
        #expect(buffer.bytes.count == 3 * alignment)
        #expect(buffer.bytes.allSatisfy { $0 == 0 })
    }

    @Test func blockSizeInitUsesAtLeastPageAlignment() throws {
        let page = Int(getpagesize())
        #expect(try AlignedBuffer(count: 4096, blockSize: 512).alignment == page)
        #expect(try AlignedBuffer(count: 4 * page, blockSize: 4 * page).alignment == 4 * page)
    }

    @Test func rejectsBadParameters() {
        #expect(posixCode { _ = try AlignedBuffer(count: 0, alignment: 4096) } == EINVAL)
        #expect(posixCode { _ = try AlignedBuffer(count: 4096, alignment: 3000) } == EINVAL)
    }

    @Test func zeroClearsOnlyTheRange() throws {
        let buffer = try AlignedBuffer(count: 1024, alignment: 512)
        buffer.bytes.copyBytes(from: [UInt8](repeating: 0xFF, count: 1024))
        buffer.zero(1000..<1024)
        #expect(buffer.bytes[999] == 0xFF)
        #expect(buffer.bytes[1000..<1024].allSatisfy { $0 == 0 })
    }
}

struct BlockMathTests {
    @Test func roundUp() {
        #expect(BlockMath.roundUp(0, to: 512) == 0)
        #expect(BlockMath.roundUp(1, to: 512) == 512)
        #expect(BlockMath.roundUp(512, to: 512) == 512)
        #expect(BlockMath.roundUp(513, to: 4096) == 4096)
    }

    @Test func alignment() {
        #expect(BlockMath.isAligned(UInt64(8192), to: 4096))
        #expect(!BlockMath.isAligned(UInt64(1), to: 512))
        #expect(BlockMath.isAligned(0, to: 512))
        #expect(!BlockMath.isAligned(100, to: 512))
        #expect(!BlockMath.isAligned(-512, to: 512))
        #expect(!BlockMath.isAligned(512, to: 0))
    }

    @Test func geometry() {
        #expect(BlockMath.isValidGeometry(blockSize: 512, blockCount: 1))
        #expect(!BlockMath.isValidGeometry(blockSize: 0, blockCount: 1))
        #expect(!BlockMath.isValidGeometry(blockSize: 1000, blockCount: 1))
        #expect(!BlockMath.isValidGeometry(blockSize: 512, blockCount: 0))
        #expect(!BlockMath.isValidGeometry(blockSize: 4096, blockCount: .max))
    }
}
