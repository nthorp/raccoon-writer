import Foundation
import Testing
@testable import ImageWriterCore

struct BootDiskResolverTests {
    typealias F = DiskutilFixtures

    func resolve(_ responses: [[String]: CommandResult]) async throws -> BootDiskSet {
        try await BootDiskResolver(runner: FakeCommandRunner(responses: responses)).resolveBootDisks()
    }

    @Test func resolvesContainerAndPhysicalStore() async throws {
        let runner = try F.runner()
        let boot = try await BootDiskResolver(runner: runner).resolveBootDisks()
        #expect(boot.wholeDisks == ["disk0", "disk3"])
        #expect(runner.invocations == [F.info("/"), F.info("disk0s2")])
    }

    @Test func everyStoreOfAFusionStyleContainerIsIncluded() async throws {
        var root = try F.dictionary("info-root")
        root["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk1s2"]]
        let boot = try await resolve([
            F.info("/"): try F.plist(root),
            F.info("disk0s2"): try F.ok("info-disk0s2"),
            F.info("disk1s2"): try F.plist(["DeviceIdentifier": "disk1s2", "ParentWholeDisk": "disk1"]),
        ])
        #expect(boot.wholeDisks == ["disk0", "disk1", "disk3"])
    }

    @Test func externalUSBBootDiskIsResolved() async throws {
        let boot = try await resolve([
            F.info("/"): try F.plist([
                "DeviceIdentifier": "disk6s1s1", "ParentWholeDisk": "disk6", "FilesystemType": "apfs",
                "APFSContainerReference": "disk6", "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]],
            ]),
            F.info("disk4s2"): try F.plist(["DeviceIdentifier": "disk4s2", "ParentWholeDisk": "disk4"]),
        ])
        #expect(boot.wholeDisks == ["disk4", "disk6"])
    }

    @Test func nonAPFSRootNeedsNoStores() async throws {
        let boot = try await resolve([
            F.info("/"): try F.plist(["DeviceIdentifier": "disk2s2", "ParentWholeDisk": "disk2", "FilesystemType": "hfs"]),
        ])
        #expect(boot.wholeDisks == ["disk2"])
    }

    @Test func rootQueryFailureThrows() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await resolve([F.info("/"): try F.notFound()])
        }
    }

    @Test func storeQueryFailureThrows() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await resolve([F.info("/"): try F.ok("info-root")])
        }
    }

    @Test func missingParentThrows() async throws {
        var root = try F.dictionary("info-root")
        root["ParentWholeDisk"] = nil
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "diskutil reported no whole disk for /")) {
            _ = try await resolve([F.info("/"): try F.plist(root), F.info("disk0s2"): try F.ok("info-disk0s2")])
        }
    }

    @Test func storeWithoutParentThrows() async throws {
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "diskutil reported no whole disk for disk0s2")) {
            _ = try await resolve([F.info("/"): try F.ok("info-root"), F.info("disk0s2"): try F.plist(["DeviceIdentifier": "disk0s2"])])
        }
    }

    @Test(arguments: ["disk3s1", "disk3; ls", "", "/dev/disk3"])
    func invalidParentNameThrows(_ parent: String) async throws {
        var root = try F.dictionary("info-root")
        root["ParentWholeDisk"] = parent
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "diskutil reported no whole disk for /")) {
            _ = try await resolve([F.info("/"): try F.plist(root), F.info("disk0s2"): try F.ok("info-disk0s2")])
        }
    }

    @Test func apfsRootWithoutStoresThrows() async throws {
        var root = try F.dictionary("info-root")
        root["APFSPhysicalStores"] = nil
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "the APFS boot volume lists no physical store")) {
            _ = try await resolve([F.info("/"): try F.plist(root)])
        }
    }

    @Test func invalidStoreNameIsNeverQueried() async throws {
        var root = try F.dictionary("info-root")
        root["APFSPhysicalStores"] = [["APFSPhysicalStore": "disk0s2; rm -rf ~"]]
        let runner = FakeCommandRunner(responses: [F.info("/"): try F.plist(root)])
        await #expect(throws: DiskDiscoveryError.invalidIdentifier("disk0s2; rm -rf ~")) {
            _ = try await BootDiskResolver(runner: runner).resolveBootDisks()
        }
        #expect(runner.invocations == [F.info("/")])
    }

    @Test func bootDiskSetIsNeverEmptyOrPartial() {
        #expect(BootDiskSet([]) == nil)
        #expect(BootDiskSet(["disk0", "disk0s2"]) == nil)
        #expect(BootDiskSet(["disk0"])?.contains("disk0") == true)
    }
}
