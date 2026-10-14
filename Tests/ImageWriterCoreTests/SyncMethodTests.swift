import Foundation
import Testing
@testable import ImageWriterCore

struct SyncMethodTests {
    /// Records which calls ran, and feeds each one its scripted results in order.
    private final class Calls {
        var log: [SyncMethod] = []
        var skipped: [(SyncMethod, Int32)] = []
        private var results: [SyncMethod: [Int32]]

        init(synchronize: [Int32] = [0], fullFsync: [Int32] = [0], fsync: [Int32] = [0]) {
            results = [.synchronize: synchronize, .fullFsync: fullFsync, .fsyncFallback: fsync]
        }

        func perform() throws -> SyncMethod {
            try SyncMethod.perform(
                synchronize: { self.call(.synchronize) },
                fullFsync: { self.call(.fullFsync) },
                fsync: { self.call(.fsyncFallback) },
                onSkip: { self.skipped.append(($0, $1)) }
            )
        }

        private func call(_ method: SyncMethod) -> Int32 {
            log.append(method)
            return results[method]?.removeFirst() ?? 0
        }
    }

    @Test func synchronizeSucceeds() throws {
        let calls = Calls()
        #expect(try calls.perform() == .synchronize)
        #expect(calls.log == [.synchronize])
        #expect(calls.skipped.isEmpty)
    }

    @Test(arguments: [ENOTTY, ENOTSUP])
    func unsupportedSynchronizeFallsBackToFullFsync(_ code: Int32) throws {
        let calls = Calls(synchronize: [code])
        #expect(try calls.perform() == .fullFsync)
        #expect(calls.log == [.synchronize, .fullFsync])
        #expect(calls.skipped.map(\.0) == [.synchronize])
        #expect(calls.skipped.map(\.1) == [code])
    }

    @Test(arguments: [ENOTTY, ENOTSUP])
    func unsupportedFullFsyncFallsBackToFsync(_ code: Int32) throws {
        let calls = Calls(synchronize: [ENOTTY], fullFsync: [code])
        #expect(try calls.perform() == .fsyncFallback)
        #expect(calls.log == [.synchronize, .fullFsync, .fsyncFallback])
        #expect(calls.skipped.map(\.0) == [.synchronize, .fullFsync])
        #expect(calls.skipped.map(\.1) == [ENOTTY, code])
    }

    @Test(arguments: [EIO, ENXIO, EINVAL])
    func otherSynchronizeErrorsAreFatal(_ code: Int32) {
        let calls = Calls(synchronize: [code])
        #expect(throws: DeviceIOError.posix(operation: "ioctl(DKIOCSYNCHRONIZE)", code: code)) { try calls.perform() }
        #expect(calls.log == [.synchronize])
        #expect(calls.skipped.isEmpty)
    }

    @Test(arguments: [EIO, ENXIO, EINVAL])
    func otherFullFsyncErrorsAreFatal(_ code: Int32) {
        let calls = Calls(synchronize: [ENOTTY], fullFsync: [code])
        #expect(throws: DeviceIOError.posix(operation: "F_FULLFSYNC", code: code)) { try calls.perform() }
        #expect(calls.log == [.synchronize, .fullFsync])
    }

    @Test(arguments: [EIO, ENXIO, ENOTTY])
    func fsyncFailureIsFatal(_ code: Int32) {
        let calls = Calls(synchronize: [ENOTSUP], fullFsync: [ENOTTY], fsync: [code])
        #expect(throws: DeviceIOError.posix(operation: "fsync", code: code)) { try calls.perform() }
        #expect(calls.log == [.synchronize, .fullFsync, .fsyncFallback])
    }

    @Test func eachStepRetriesOnEINTR() throws {
        let synchronize = Calls(synchronize: [EINTR, EINTR, 0])
        #expect(try synchronize.perform() == .synchronize)
        #expect(synchronize.log == [.synchronize, .synchronize, .synchronize])

        let fullFsync = Calls(synchronize: [EINTR, ENOTTY], fullFsync: [EINTR, 0])
        #expect(try fullFsync.perform() == .fullFsync)
        #expect(fullFsync.log == [.synchronize, .synchronize, .fullFsync, .fullFsync])

        let fsync = Calls(synchronize: [ENOTTY], fullFsync: [ENOTTY], fsync: [EINTR, EINTR, 0])
        #expect(try fsync.perform() == .fsyncFallback)
        #expect(fsync.log == [.synchronize, .fullFsync, .fsyncFallback, .fsyncFallback, .fsyncFallback])
    }
}
