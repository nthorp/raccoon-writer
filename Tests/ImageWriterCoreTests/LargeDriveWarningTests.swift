import Foundation
import Testing
@testable import ImageWriterCore

struct LargeDriveWarningTests {
    @Test(arguments: [UInt64(0), 30_752_636_928, 500_000_000_000])
    func noWarningAtOrBelowTheThreshold(_ sizeBytes: UInt64) {
        #expect(LargeDriveWarning(drive: .usbStick(sizeBytes: sizeBytes)) == nil)
    }

    @Test(arguments: [UInt64(500_000_000_001), 500_107_862_016, 1_000_204_886_016])
    func warnsAboveTheThreshold(_ sizeBytes: UInt64) throws {
        let warning = try #require(LargeDriveWarning(drive: .usbStick(sizeBytes: sizeBytes)))
        #expect(warning.driveBytes == sizeBytes)
        #expect(warning.message.contains(DisplayFormat.size(sizeBytes)))
    }

    @Test func messageNamesTheDriveSizeNotTheThreshold() throws {
        let warning = try #require(LargeDriveWarning(drive: .usbStick(sizeBytes: 1_000_204_886_016)))
        #expect(warning.message.contains("(1 TB)"))
        #expect(!warning.message.contains("500 GB"))
    }
}
