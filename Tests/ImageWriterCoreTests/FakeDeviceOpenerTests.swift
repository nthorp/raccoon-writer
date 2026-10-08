import Foundation
import Testing
@testable import ImageWriterCore

struct FakeDeviceOpenerTests {
    @Test func returnsPreparedDevice() async throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 4)
        let opener = FakeDeviceOpener(device: device)
        let opened = try await opener.openForReadWrite(bsdName: "disk4")
        #expect(opened === device)
        #expect(opener.openAttempts == ["disk4"])
    }

    @Test func throwsPreparedError() async {
        let opener = FakeDeviceOpener(error: .userCancelled)
        await #expect(throws: DeviceOpenError.userCancelled) {
            _ = try await opener.openForReadWrite(bsdName: "disk4")
        }
        #expect(opener.openAttempts == ["disk4"])
    }

    @Test func rejectsInvalidNamesLikeProduction() async throws {
        let opener = FakeDeviceOpener(device: try FileBackedDevice(blockSize: 512, blockCount: 4))
        await #expect(throws: DeviceOpenError.invalidDiskName("disk4s1")) {
            _ = try await opener.openForReadWrite(bsdName: "disk4s1")
        }
        #expect(opener.openAttempts.isEmpty)
    }
}
