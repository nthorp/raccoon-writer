import Foundation
import Testing
@testable import ImageWriterCore

struct SyncMethodTests {
    @Test func fullFsyncSucceeds() throws {
        var fsyncCalled = false
        let method = try SyncMethod.perform(fullFsync: { 0 }, fsync: { fsyncCalled = true; return 0 })
        #expect(method == .fullFsync)
        #expect(!fsyncCalled)
    }

    @Test(arguments: [ENOTTY, ENOTSUP])
    func unsupportedFallsBackToFsync(_ code: Int32) throws {
        let method = try SyncMethod.perform(fullFsync: { code }, fsync: { 0 })
        #expect(method == .fsyncFallback)
    }

    @Test func otherFullFsyncErrorsAreFatal() {
        var fsyncCalled = false
        let code = posixCode { _ = try SyncMethod.perform(fullFsync: { EIO }, fsync: { fsyncCalled = true; return 0 }) }
        #expect(code == EIO)
        #expect(!fsyncCalled)
    }

    @Test func fallbackFailureIsFatal() {
        #expect(throws: DeviceIOError.posix(operation: "fsync", code: ENXIO)) {
            try SyncMethod.perform(fullFsync: { ENOTTY }, fsync: { ENXIO })
        }
    }

    @Test func retriesOnEINTR() throws {
        var results: [Int32] = [EINTR, EINTR, 0]
        let method = try SyncMethod.perform(fullFsync: { results.removeFirst() }, fsync: { 0 })
        #expect(method == .fullFsync)
        #expect(results.isEmpty)
    }
}
