import Foundation

/// Thin EINTR-retrying wrappers over `pread`/`pwrite`/`fcntl`, shared by the real and fake devices.
enum PosixIO {
    static func offset(_ value: UInt64, for operation: String) throws -> off_t {
        guard let offset = off_t(exactly: value) else {
            throw DeviceIOError.posix(operation: operation, code: EINVAL)
        }
        return offset
    }

    static func pread(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let position = try self.offset(offset, for: "read")
        while true {
            let count = Darwin.pread(fd, buffer.baseAddress, buffer.count, position)
            if count >= 0 { return count }
            if errno != EINTR { throw DeviceIOError.posix(operation: "read at offset \(offset)", code: errno) }
        }
    }

    static func pwrite(_ fd: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        let position = try self.offset(offset, for: "write")
        while true {
            let count = Darwin.pwrite(fd, buffer.baseAddress, buffer.count, position)
            if count >= 0 { return count }
            if errno != EINTR { throw DeviceIOError.posix(operation: "write at offset \(offset)", code: errno) }
        }
    }

    /// Returns 0 or the errno, in the shape `SyncMethod.perform` expects.
    static func fcntlStatus(_ fd: Int32, _ command: Int32) -> Int32 {
        fcntl(fd, command) == -1 ? errno : 0
    }

    static func fsyncStatus(_ fd: Int32) -> Int32 {
        Darwin.fsync(fd) == -1 ? errno : 0
    }
}
