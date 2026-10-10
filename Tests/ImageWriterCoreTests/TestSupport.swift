import Foundation
import os
@testable import ImageWriterCore

/// Runs `body` and returns the errno of the `DeviceIOError.posix` it throws, or nil otherwise.
func posixCode(_ body: () throws -> Void) -> Int32? {
    do {
        try body()
        return nil
    } catch DeviceIOError.posix(_, let code) {
        return code
    } catch {
        return nil
    }
}

/// Bytes whose value depends on position, so offset bugs show up as mismatches.
func pattern(count: Int, seed: UInt8 = 0xA5) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 >> 9) ^ ($0 & 0xff)) ^ seed }
}

/// A fresh empty file in the temp directory, opened read-write. Caller closes and removes it.
func makeTempFile() throws -> (url: URL, fd: Int32) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-test-\(UUID().uuidString)")
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DeviceIOError.posix(operation: "open", code: errno) }
    return (url, fd)
}

extension OpenedDevice {
    func write(_ bytes: [UInt8], at offset: UInt64) throws -> Int {
        try bytes.withUnsafeBytes { try write(from: $0, at: offset) }
    }

    func read(count: Int, at offset: UInt64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let n = try bytes.withUnsafeMutableBytes { try read(into: $0, at: offset) }
        return Array(bytes.prefix(n))
    }
}

/// A fake clock that advances by `step` seconds each time it is read.
func steppingClock(step: TimeInterval, start: TimeInterval = 1000) -> MonotonicClock {
    let time = OSAllocatedUnfairLock(initialState: start)
    return MonotonicClock {
        time.withLock { now in
            defer { now += step }
            return now
        }
    }
}

/// Collects values handed over on another thread.
final class Recorder<Value: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock<[Value]>(initialState: [])

    func append(_ value: Value) {
        state.withLock { $0.append(value) }
    }

    var values: [Value] { state.withLock { $0 } }
}
