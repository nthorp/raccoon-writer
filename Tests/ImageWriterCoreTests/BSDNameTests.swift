import Testing
@testable import ImageWriterCore

struct BSDNameTests {
    @Test(arguments: ["disk0", "disk4", "disk12", "disk999"])
    func acceptsWholeDisks(_ name: String) {
        #expect(BSDName.isWholeDisk(name))
    }

    @Test(arguments: [
        "", "disk", "disk4s1", "rdisk4", "/dev/disk4", "/dev/rdisk4", "disk4;ls", "disk4 ",
        " disk4", "disk4\n", "Disk4", "disk-4", "disk٣", "disk４", "disk99999999999999",
    ])
    func rejectsEverythingElse(_ name: String) {
        #expect(!BSDName.isWholeDisk(name))
    }
}
