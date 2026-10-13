import Foundation
import Testing
@testable import ImageWriterCore

struct FakeDeviceOpenerTests {
    @Test func grantOpensThePreparedDevice() async throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: 4)
        let opener = FakeDeviceOpener(device: device)
        let grant = try await opener.authorize(bsdName: "disk4")
        #expect(opener.openAttempts.isEmpty)
        let opened = try await grant.open()
        #expect(opened === device)
        #expect(grant.bsdName == "disk4")
        #expect(opener.authorizeAttempts == ["disk4"])
        #expect(opener.openAttempts == ["disk4"])
    }

    @Test func authorizeErrorComesFromAuthorize() async {
        let opener = FakeDeviceOpener(authorizeError: .userCancelled)
        await #expect(throws: DeviceOpenError.userCancelled) {
            _ = try await opener.authorize(bsdName: "disk4")
        }
        #expect(opener.authorizeAttempts == ["disk4"])
        #expect(opener.grants.isEmpty)
    }

    @Test func openErrorComesFromTheGrant() async throws {
        let opener = FakeDeviceOpener(openError: .deviceBusy)
        let grant = try await opener.authorize(bsdName: "disk4")
        await #expect(throws: DeviceOpenError.deviceBusy) { _ = try await grant.open() }
        #expect(opener.openAttempts == ["disk4"])
    }

    @Test func grantCountsReleasesAndRefusesToOpenAfterOne() async throws {
        let opener = FakeDeviceOpener(device: try FileBackedDevice(blockSize: 512, blockCount: 4))
        let grant = try await opener.authorize(bsdName: "disk4")
        grant.release()
        await #expect(throws: DeviceOpenError.permissionDenied) { _ = try await grant.open() }
        #expect(opener.grants.map(\.releaseCount) == [1])
        #expect(opener.openAttempts.isEmpty)
    }

    @Test func rejectsInvalidNamesLikeProduction() async throws {
        let opener = FakeDeviceOpener(device: try FileBackedDevice(blockSize: 512, blockCount: 4))
        await #expect(throws: DeviceOpenError.invalidDiskName("disk4s1")) {
            _ = try await opener.authorize(bsdName: "disk4s1")
        }
        #expect(opener.authorizeAttempts.isEmpty)
    }
}
