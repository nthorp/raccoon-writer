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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-test-\(UUID().uuidString)")
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw DeviceIOError.posix(operation: "open", code: errno) }
    return (url, fd)
}

/// The identity `ImageInspector` would record for the file at `url`.
func fileIdentity(at url: URL) throws -> FileIdentity {
    var info = stat()
    guard stat(url.path, &info) == 0 else { throw DeviceIOError.posix(operation: "stat", code: errno) }
    return FileIdentity(info)
}

/// The mount point `ImageInspector` would record for the file at `url`.
func volumeMountPoint(at url: URL) throws -> String {
    var volume = statfs()
    guard statfs(url.path, &volume) == 0 else { throw DeviceIOError.posix(operation: "statfs", code: errno) }
    return ImageInspector.mountPoint(of: volume)
}

/// An `ImageInfo` for a raw image already written at `url`, with the file's real size,
/// identity and mount point, as `ImageInspector` would record them. Boot signatures are
/// left off.
func imageInfo(at url: URL) throws -> ImageInfo {
    let identity = try fileIdentity(at: url)
    return ImageInfo(
        url: url, fileName: url.lastPathComponent, sizeBytes: UInt64(identity.sizeBytes), identity: identity,
        volumeMountPoint: try volumeMountPoint(at: url),
        kind: .img, hasMBR: false, hasGPT: false, isISO9660: false, bootWarning: nil
    )
}

extension FileIdentity {
    /// For an `ImageInfo` that is never opened, such as one only shown on screen.
    static let madeUp = FileIdentity(device: 1, inode: 2, sizeBytes: 3, modifiedSeconds: 4, modifiedNanoseconds: 5)
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
