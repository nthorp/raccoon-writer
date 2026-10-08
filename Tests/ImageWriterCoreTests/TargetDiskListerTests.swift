import Foundation
import Testing
@testable import ImageWriterCore

/// The T03 acceptance criteria, end to end over the fixture machine.
struct TargetDiskListerTests {
    typealias F = DiskutilFixtures

    func targets(showAllExternal: Bool, overriding overrides: [[String]: CommandResult] = [:]) async throws -> [String] {
        try await TargetDiskLister(runner: try F.runner(overriding: overrides))
            .targets(showAllExternal: showAllExternal)
            .map(\.bsdName)
    }

    @Test func defaultListShowsOnlyTheUSBStick() async throws {
        #expect(try await targets(showAllExternal: false) == ["disk4"])
    }

    @Test func toggleAddsThunderboltSSDAndSDCard() async throws {
        #expect(try await targets(showAllExternal: true) == ["disk4", "disk5", "disk7"])
    }

    @Test(arguments: [false, true])
    func bootInternalContainersAndImagesNeverAppear(showAllExternal: Bool) async throws {
        let shown = try await targets(showAllExternal: showAllExternal)
        for hidden in ["disk0", "disk3", "disk6", "disk8"] {
            #expect(!shown.contains(hidden))
        }
    }

    @Test func eachFixtureDiskIsRejectedForTheExpectedReason() async throws {
        let disks = try await DiskutilDiscovery(runner: try F.runner()).listDisks()
        let reasons = Dictionary(uniqueKeysWithValues: disks.map {
            ($0.bsdName, DiskFilter(showAllExternal: true).rejection(for: $0, bootDisks: .fixture))
        })
        #expect(reasons["disk0"] == .internalDisk)
        #expect(reasons["disk3"] == .internalDisk)
        #expect(reasons["disk6"] == .apfsContainer)
        #expect(reasons["disk8"] == .virtualDisk)
    }

    @Test(arguments: [false, true])
    func failsClosedWhenTheBootDiskCannotBeResolved(showAllExternal: Bool) async throws {
        let runner = try F.runner(overriding: [F.info("/"): try F.notFound()])
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await TargetDiskLister(runner: runner).targets(showAllExternal: showAllExternal)
        }
        #expect(!runner.invocations.contains(F.list))
    }

    @Test func failsClosedWhenTheAPFSStoreCannotBeResolved() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await targets(showAllExternal: true, overriding: [F.info("disk0s2"): try F.notFound()])
        }
    }

    @Test func failsClosedWhenTheResolverThrows() async throws {
        let lister = TargetDiskLister(discovery: StubDiscovery(disks: [.usbStick()]), bootResolver: FailingResolver())
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "stub")) {
            _ = try await lister.targets(showAllExternal: false)
        }
    }

    @Test func discoveryFailureThrows() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await targets(showAllExternal: false, overriding: [F.list: CommandResult(status: 1)])
        }
    }
}

private struct StubDiscovery: DiskDiscovery {
    let disks: [DiskInfo]
    func listDisks() async throws -> [DiskInfo] { disks }
}

private struct FailingResolver: BootDiskResolving {
    func resolveBootDisks() async throws -> BootDiskSet {
        throw DiskDiscoveryError.bootDiskUnresolved(reason: "stub")
    }
}
