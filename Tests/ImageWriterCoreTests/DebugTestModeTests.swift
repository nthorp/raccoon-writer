#if DEBUG
import Foundation
import Testing
@testable import ImageWriterCore

struct DebugTestModeTests {
    let boot = BootDiskSet.fixture

    func filters(allowVirtual: Bool) -> [DiskFilter] {
        [false, true].map { DiskFilter(showAllExternal: $0, allowVirtualDisks: allowVirtual) }
    }

    func rejections(_ disk: DiskInfo, allowVirtual: Bool = true) -> [DiskRejection?] {
        filters(allowVirtual: allowVirtual).map { $0.rejection(for: disk, bootDisks: boot) }
    }

    @Test func environmentSwitchIsExactlyOne() {
        let key = DebugTestMode.environmentKey
        #expect(key == "RACCOONWRITER_ALLOW_VIRTUAL_DISKS")
        #expect(DebugTestMode.allowsVirtualDisks(environment: [key: "1"]))
        for value in ["", "0", "true", "yes", " 1", "1 "] {
            #expect(!DebugTestMode.allowsVirtualDisks(environment: [key: value]))
        }
        #expect(!DebugTestMode.allowsVirtualDisks(environment: [:]))
    }

    @Test func filtersRejectVirtualDisksByDefault() {
        #expect(DiskFilter().allowVirtualDisks == false)
        #expect(DiskFilter(showAllExternal: true).allowVirtualDisks == false)
        #expect(rejections(.ramDisk(), allowVirtual: false) == [.virtualDisk, .virtualDisk])
    }

    @Test func unmountedRAMDiskIsAcceptedUnderBothSettings() {
        #expect(rejections(.ramDisk()) == [nil, nil])
    }

    @Test func mountedDiskImageIsStillRejected() {
        var disk = DiskInfo.ramDisk()
        disk.mountPoints = ["/Library/Developer/CoreSimulator/Volumes/iOS_23A343"]
        #expect(rejections(disk) == [.virtualDisk, .virtualDisk])
    }

    @Test func safetyRulesStillApplyToVirtualDisks() {
        var disk = DiskInfo.ramDisk()
        disk.isAPFSContainer = true
        #expect(rejections(disk) == [.apfsContainer, .apfsContainer])

        disk = .ramDisk()
        disk.isInternal = true
        #expect(rejections(disk) == [.internalDisk, .internalDisk])

        disk = .ramDisk()
        disk.isWholeDisk = false
        #expect(rejections(disk) == [.notWholeDisk, .notWholeDisk])

        disk = .ramDisk()
        disk.sizeBytes = 0
        #expect(rejections(disk) == [.noMedia, .noMedia])

        let ramBoot = BootDiskSet(["disk9"])!
        for filter in filters(allowVirtual: true) {
            #expect(filter.rejection(for: .ramDisk(), bootDisks: ramBoot) == .bootDisk)
        }
    }

    @Test func physicalDisksAreUnaffected() {
        var notUSB = DiskInfo.usbStick()
        notUSB.busProtocol = "PCI-Express"
        #expect(rejections(.usbStick()) == [nil, nil])
        #expect(rejections(notUSB) == [.notUSB, nil])
    }

    @Test func fixtureDiskImageStaysHiddenBecauseItIsMounted() async throws {
        let lister = TargetDiskLister(runner: try DiskutilFixtures.runner())
        for showAll in [false, true] {
            let shown = try await lister.targets(filter: DiskFilter(showAllExternal: showAll, allowVirtualDisks: true))
            #expect(!shown.map(\.bsdName).contains("disk8"))
        }
    }

    @Test func safetyGuardAcceptsTheRAMDiskOnlyWithTheSwitch() async throws {
        let guardian = SafetyGuard(discovery: RAMDiskDiscovery(), bootResolver: FixtureResolver())
        let accepted = try await guardian.validate(
            confirmed: .ramDisk(),
            filter: DiskFilter(showAllExternal: false, allowVirtualDisks: true)
        )
        #expect(accepted == .ramDisk())
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk9", reason: .virtualDisk)) {
            try await guardian.validate(confirmed: .ramDisk(), filter: DiskFilter(showAllExternal: true))
        }
    }
}

extension DiskInfo {
    /// What `hdiutil attach -nomount ram://65536` looks like (T01).
    static func ramDisk(_ bsdName: String = "disk9") -> DiskInfo {
        DiskInfo(
            bsdName: bsdName,
            mediaName: "Disk Image",
            sizeBytes: 33_554_432,
            blockSize: 512,
            busProtocol: "Disk Image",
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isVirtual: true,
            isWholeDisk: true
        )
    }
}

private struct RAMDiskDiscovery: DiskDiscovery {
    func listDisks() async throws -> [DiskInfo] { [.usbStick(), .ramDisk()] }
}

private struct FixtureResolver: BootDiskResolving {
    func resolveBootDisks() async throws -> BootDiskSet { .fixture }
}
#endif
