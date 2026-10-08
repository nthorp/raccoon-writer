import Foundation

// <sys/disk.h> macros are not importable into Swift. Values checked against the
// C headers: _IOR('d', 24, uint32_t) and _IOR('d', 25, uint64_t).
let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

struct Geometry {
    var blockSize: UInt32
    var blockCount: UInt64
    var byteCount: UInt64 { UInt64(blockSize) * blockCount }
}

func deviceGeometry(fd: Int32) throws -> Geometry {
    var blockSize: UInt32 = 0
    var blockCount: UInt64 = 0
    guard ioctl(fd, DKIOCGETBLOCKSIZE, &blockSize) == 0 else {
        throw SpikeError.posix("ioctl(DKIOCGETBLOCKSIZE)", errno: errno)
    }
    guard ioctl(fd, DKIOCGETBLOCKCOUNT, &blockCount) == 0 else {
        throw SpikeError.posix("ioctl(DKIOCGETBLOCKCOUNT)", errno: errno)
    }
    return Geometry(blockSize: blockSize, blockCount: blockCount)
}

/// posix_memalign-backed buffer; raw devices require aligned memory and lengths.
final class AlignedBuffer {
    let pointer: UnsafeMutableRawPointer
    let count: Int

    init(count: Int, alignment: Int) throws {
        var raw: UnsafeMutableRawPointer?
        let status = posix_memalign(&raw, alignment, count)
        guard status == 0, let raw else { throw SpikeError.posix("posix_memalign", errno: status) }
        pointer = raw
        self.count = count
    }

    deinit { free(pointer) }
}

/// Byte i depends on its position so offset and ordering bugs show up as mismatches.
func fillPattern(_ buffer: AlignedBuffer) {
    let bytes = buffer.pointer.assumingMemoryBound(to: UInt8.self)
    for i in 0..<buffer.count {
        bytes[i] = UInt8(truncatingIfNeeded: (i >> 9) ^ (i & 0xff) ^ 0xA5)
    }
}

/// Writes all bytes, retrying the remainder after short writes, and reports them.
func writeFully(fd: Int32, from buffer: AlignedBuffer, offset: off_t) throws -> Int {
    var done = 0
    var shortWrites = 0
    while done < buffer.count {
        let n = pwrite(fd, buffer.pointer + done, buffer.count - done, offset + off_t(done))
        if n < 0 {
            if errno == EINTR { continue }
            throw SpikeError.posix("pwrite at \(offset + off_t(done))", errno: errno)
        }
        if n == 0 { throw SpikeError.posix("pwrite returned 0", errno: EIO) }
        if done + n < buffer.count { shortWrites += 1 }
        done += n
    }
    return shortWrites
}

func readFully(fd: Int32, into buffer: AlignedBuffer, offset: off_t) throws -> Int {
    var done = 0
    var shortReads = 0
    while done < buffer.count {
        let n = pread(fd, buffer.pointer + done, buffer.count - done, offset + off_t(done))
        if n < 0 {
            if errno == EINTR { continue }
            throw SpikeError.posix("pread at \(offset + off_t(done))", errno: errno)
        }
        if n == 0 { throw SpikeError.posix("pread hit end of device", errno: EIO) }
        if done + n < buffer.count { shortReads += 1 }
        done += n
    }
    return shortReads
}

/// Read-only probe: how does the raw node react to a request that is not
/// block-aligned? The result tells T02 what the fake device must emulate.
func probeUnalignedRead(fd: Int32, length: Int, offset: off_t, alignedMemory: Bool) -> String {
    let result: Int
    let code: Int32
    if alignedMemory, let buffer = try? AlignedBuffer(count: max(length, 1), alignment: Int(getpagesize())) {
        result = pread(fd, buffer.pointer, length, offset)
        code = errno
    } else {
        // Offset by one byte from a heap allocation to force misaligned memory.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: length + 1, alignment: 16)
        defer { raw.deallocate() }
        result = pread(fd, raw + 1, length, offset)
        code = errno
    }
    let memory = alignedMemory ? "aligned memory" : "misaligned memory"
    if result < 0 {
        return "pread(len \(length), offset \(offset), \(memory)) -> -1, errno \(code) (\(String(cString: strerror(code))))"
    }
    return "pread(len \(length), offset \(offset), \(memory)) -> \(result) bytes"
}
