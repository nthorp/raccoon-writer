import Testing
@testable import ImageWriterCore

struct BSDNameTests {
    @Test(arguments: ["disk0", "disk4", "disk12", "disk999"])
    func acceptsWholeDisks(_ name: String) {
        #expect(BSDName.isWholeDisk(name))
        #expect(BSDName.isDeviceIdentifier(name))
    }

    @Test(arguments: [
        "", "disk", "disk4s1", "rdisk4", "/dev/disk4", "/dev/rdisk4", "disk4;ls", "disk4 ",
        " disk4", "disk4\n", "Disk4", "disk-4", "disk٣", "disk４", "disk99999999999999",
    ])
    func rejectsEverythingElse(_ name: String) {
        #expect(!BSDName.isWholeDisk(name))
    }

    @Test(arguments: ["disk0s2", "disk3s3s1", "disk12s10"])
    func deviceIdentifiersIncludeSlices(_ name: String) {
        #expect(BSDName.isDeviceIdentifier(name))
        #expect(!BSDName.isWholeDisk(name))
    }

    @Test(arguments: [
        "", "disk", "disks1", "disk4s", "disk4ss1", "disk4s1s", "rdisk4s1", "/dev/disk4s1",
        "disk4s1;ls", "disk4p1", "disk4s١", "disk0s2 ", "/", "disk0s2s2s2s2s2s2s2s2s2s2s2s2s2s2",
    ])
    func rejectsMalformedDeviceIdentifiers(_ name: String) {
        #expect(!BSDName.isDeviceIdentifier(name))
    }
}
