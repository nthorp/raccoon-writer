import Foundation
import Testing
@testable import ImageWriterCore

/// The T08 acceptance criteria, over the fixture machine and stubs.
struct SafetyGuardTests {
    typealias F = DiskutilFixtures

    let defaultFilter = DiskFilter(showAllExternal: false)
    let allExternal = DiskFilter(showAllExternal: true)

    /// The disk as the drive list showed it.
    func confirmed(_ name: String = "disk4") async throws -> DiskInfo {
        let disks = try await DiskutilDiscovery(runner: try F.runner()).listDisks()
        return try #require(disks.first { $0.bsdName == name })
    }

    /// disk4's info plist with some keys replaced.
    func disk4Info(_ changes: [String: Any]) throws -> [[String]: CommandResult] {
        let info = try F.dictionary("info-disk4").merging(changes) { _, new in new }
        return [F.info("disk4"): try F.plist(info)]
    }

    func validate(
        _ disk: DiskInfo,
        filter: DiskFilter? = nil,
        overriding overrides: [[String]: CommandResult] = [:]
    ) async throws -> DiskInfo {
        let runner = try F.runner(overriding: overrides)
        return try await SafetyGuard(runner: runner).validate(confirmed: disk, filter: filter ?? defaultFilter)
    }

    // MARK: Unchanged disks pass

    @Test func unchangedDiskPasses() async throws {
        let disk = try await confirmed()
        #expect(try await validate(disk) == disk)
    }

    @Test func diskShownOnlyUnderShowAllExternalPassesUnderThatSetting() async throws {
        for name in ["disk5", "disk7"] {
            let disk = try await confirmed(name)
            #expect(try await validate(disk, filter: allExternal) == disk)
        }
    }

    @Test func changedMountsAreNotAnIdentityChangeAndTheFreshDiskIsReturned() async throws {
        let disk = try await confirmed()
        var stale = disk
        stale.mountPoints = ["/Volumes/OLD"]
        stale.volumeNames = ["OLD"]
        #expect(try await validate(stale) == disk)
    }

    // MARK: Swapped disks are rejected

    @Test func swappedDiskWithDifferentSizeIsRejected() async throws {
        let disk = try await confirmed()
        let bigger = try disk4Info(["Size": 62_008_590_336, "TotalSize": 62_008_590_336, "IOKitSize": 62_008_590_336])
        await #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)) {
            try await validate(disk, overriding: bigger)
        }
    }

    @Test func swappedDiskWithDifferentMediaNameIsRejected() async throws {
        let disk = try await confirmed()
        await #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .mediaName)) {
            try await validate(disk, overriding: try disk4Info(["MediaName": "Kingston DataTraveler"]))
        }
    }

    @Test func swappedDiskWithDifferentUUIDIsRejected() async throws {
        var disk = DiskInfo.usbStick()
        disk.mediaUUID = "11111111-2222-3333-4444-555555555555"
        var swapped = disk
        swapped.mediaUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let guardian = SafetyGuard(discovery: StubDiscovery(disks: [swapped]), bootResolver: StubResolver())
        await #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .mediaUUID)) {
            try await guardian.validate(confirmed: disk, filter: defaultFilter)
        }
    }

    // MARK: The image's own drive is rejected

    @Test func aDiskHoldingTheImageIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-guard-\(UUID().uuidString).img")
        try Data(pattern(count: 512)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var image = try imageInfo(at: url)
        let guardian = SafetyGuard(discovery: StubDiscovery(disks: []), bootResolver: StubResolver())
        let disk = DiskInfo.usbStick()

        try guardian.checkImage(image, isNotOn: disk)
        image.volumeMountPoint = "/Volumes/STICK"
        #expect(throws: SafetyGuardError.imageOnDrive(bsdName: "disk4", ImageOnDrive(fileName: image.fileName, mountPoint: "/Volumes/STICK"))) {
            try guardian.checkImage(image, isNotOn: disk)
        }
    }

    @Test(arguments: DiskIdentityField.allCases)
    func everyIdentityFieldIsCompared(_ field: DiskIdentityField) async throws {
        let disk = DiskInfo.usbStick()
        var swapped = disk
        switch field {
        case .size: swapped.sizeBytes += 512
        case .mediaName: swapped.mediaName = "Other"
        case .blockSize: swapped.blockSize = 4096
        case .busProtocol: swapped.busProtocol = "Thunderbolt"
        case .mediaUUID: swapped.mediaUUID = "11111111-2222-3333-4444-555555555555"
        }
        #expect(swapped.identityDifference(from: disk) == field)
        let guardian = SafetyGuard(discovery: StubDiscovery(disks: [swapped]), bootResolver: StubResolver())
        await #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: field)) {
            try await guardian.validate(confirmed: disk, filter: allExternal)
        }
    }

    @Test func uuidThatAppearedCountsAsChanged() {
        var current = DiskInfo.usbStick()
        current.mediaUUID = "11111111-2222-3333-4444-555555555555"
        #expect(current.identityDifference(from: .usbStick()) == .mediaUUID)
        #expect(DiskInfo.usbStick().identityDifference(from: current) == .mediaUUID)
    }

    @Test func removedDiskIsMissing() async throws {
        let disk = try await confirmed()
        await #expect(throws: SafetyGuardError.diskMissing(bsdName: "disk4")) {
            try await validate(disk, overriding: [F.info("disk4"): try F.notFound()])
        }
    }

    // MARK: Forbidden targets are rejected

    @Test func bootDiskIsRejected() async throws {
        // Booted from this very stick: the fresh boot resolution must catch it.
        let disk = DiskInfo.usbStick()
        let guardian = SafetyGuard(
            discovery: StubDiscovery(disks: [disk]),
            bootResolver: StubResolver(boot: BootDiskSet(["disk4"])!)
        )
        for filter in [defaultFilter, allExternal] {
            await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .bootDisk)) {
                try await guardian.validate(confirmed: disk, filter: filter)
            }
        }
    }

    @Test(arguments: ["disk0", "disk3"])
    func fixtureBootAndInternalDisksAreRejected(_ name: String) async throws {
        let disk = try await confirmed(name)
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: name, reason: .internalDisk)) {
            try await validate(disk, filter: allExternal)
        }
    }

    @Test func diskThatNowReportsInternalIsRejected() async throws {
        let disk = try await confirmed()
        for filter in [defaultFilter, allExternal] {
            await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .internalDisk)) {
                try await validate(disk, filter: filter, overriding: try disk4Info(["Internal": true]))
            }
        }
    }

    @Test func missingInternalKeyIsTreatedAsInternal() async throws {
        let disk = try await confirmed()
        var info = try F.dictionary("info-disk4")
        info.removeValue(forKey: "Internal")
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .internalDisk)) {
            try await validate(disk, overriding: [F.info("disk4"): try F.plist(info)])
        }
    }

    @Test func diskAllowedOnlyUnderShowAllExternalIsRejectedWithoutIt() async throws {
        let disk = try await confirmed("disk5")
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk5", reason: .notUSB)) {
            try await validate(disk)
        }
    }

    @Test(arguments: [false, true])
    func mountedDiskImageIsRejected(showAllExternal: Bool) async throws {
        let disk = try await confirmed("disk8")
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: "disk8", reason: .virtualDisk)) {
            try await validate(disk, filter: DiskFilter(showAllExternal: showAllExternal))
        }
    }

    @Test(arguments: ["disk4s1", "/dev/disk4", "disk4; ls", ""])
    func invalidNameIsRejectedBeforeAnyQuery(_ name: String) async throws {
        var disk = DiskInfo.usbStick()
        disk.bsdName = name
        let runner = try F.runner()
        await #expect(throws: SafetyGuardError.forbiddenTarget(bsdName: name, reason: .invalidName)) {
            try await SafetyGuard(runner: runner).validate(confirmed: disk, filter: allExternal)
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Query errors fail closed

    @Test func bootResolutionFailureIsRejectedWithoutListing() async throws {
        let disk = try await confirmed()
        let runner = try F.runner(overriding: [F.info("/"): try F.notFound()])
        await #expect(throws: SafetyGuardError.self) {
            try await SafetyGuard(runner: runner).validate(confirmed: disk, filter: defaultFilter)
        }
        #expect(!runner.invocations.contains(F.list))
    }

    @Test func listFailureIsRejected() async throws {
        let disk = try await confirmed()
        do {
            _ = try await validate(disk, overriding: [F.list: CommandResult(status: 1)])
            Issue.record("expected a query failure")
        } catch let error as SafetyGuardError {
            guard case .queryFailed = error else {
                Issue.record("unexpected \(error)")
                return
            }
        }
    }

    @Test func resolverErrorIsRejected() async throws {
        let guardian = SafetyGuard(discovery: StubDiscovery(disks: [.usbStick()]), bootResolver: FailingResolver())
        await #expect(throws: SafetyGuardError.queryFailed(reason: DiskDiscoveryError.bootDiskUnresolved(reason: "stub").localizedDescription)) {
            try await guardian.validate(confirmed: .usbStick(), filter: defaultFilter)
        }
    }

    @Test func diskutilThatCannotRunIsRejected() async throws {
        let failure = CommandRunnerError.timedOut(executable: F.diskutil, seconds: 30)
        let runner = FakeCommandRunner { _, _ in throw failure }
        await #expect(throws: SafetyGuardError.queryFailed(reason: failure.localizedDescription)) {
            try await SafetyGuard(runner: runner).validate(confirmed: .usbStick(), filter: defaultFilter)
        }
    }

    @Test func duplicateListingIsRejected() async throws {
        let disk = DiskInfo.usbStick()
        let guardian = SafetyGuard(discovery: StubDiscovery(disks: [disk, disk]), bootResolver: StubResolver())
        await #expect(throws: SafetyGuardError.queryFailed(reason: "disk4 was listed more than once")) {
            try await guardian.validate(confirmed: disk, filter: defaultFilter)
        }
    }

    @Test func cancellationPassesThroughUnwrapped() async throws {
        let guardian = SafetyGuard(discovery: CancelledDiscovery(), bootResolver: StubResolver())
        await #expect(throws: CancellationError.self) {
            try await guardian.validate(confirmed: .usbStick(), filter: defaultFilter)
        }
    }

    @Test func errorsDescribeWhatHappened() {
        let errors: [SafetyGuardError] = [
            .diskMissing(bsdName: "disk4"),
            .diskChanged(bsdName: "disk4", field: .size),
            .forbiddenTarget(bsdName: "disk4", reason: .bootDisk),
            .queryFailed(reason: "diskutil timed out"),
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(text.contains("disk4") || text.contains("diskutil timed out"))
            #expect(text.contains("Nothing was written") || text.contains("nothing was written"))
        }
        #expect(SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .bootDisk).localizedDescription
            .contains("macOS is running from it."))
    }
}

// MARK: - The opened device

/// `checkOpened` compares the device authopen returned with the disk `validate` returned.
struct SafetyGuardOpenedDeviceTests {
    let guardian = SafetyGuard(discovery: StubDiscovery(disks: []), bootResolver: StubResolver())

    func disk(sizeBytes: UInt64, blockSize: Int?) -> DiskInfo {
        var disk = DiskInfo.usbStick(sizeBytes: sizeBytes)
        disk.blockSize = blockSize
        return disk
    }

    @Test(arguments: [512, 4096])
    func aDeviceOfTheCheckedSizePasses(_ blockSize: Int) throws {
        let device = try FileBackedDevice(blockSize: blockSize, blockCount: 16)
        try guardian.checkOpened(device, matches: disk(sizeBytes: UInt64(blockSize * 16), blockSize: blockSize))
    }

    @Test(arguments: [15, 17, 1_000_000] as [UInt64])
    func aDeviceOfAnotherSizeIsRefused(_ blockCount: UInt64) throws {
        let device = try FileBackedDevice(blockSize: 512, blockCount: blockCount)
        #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)) {
            try guardian.checkOpened(device, matches: disk(sizeBytes: 512 * 16, blockSize: 512))
        }
    }

    @Test func aDeviceWithAnotherBlockSizeIsRefusedEvenAtTheSameByteCount() throws {
        let device = try FileBackedDevice(blockSize: 4096, blockCount: 2)
        #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .blockSize)) {
            try guardian.checkOpened(device, matches: disk(sizeBytes: 8192, blockSize: 512))
        }
    }

    @Test func anUnknownBlockSizeStillChecksTheByteCount() throws {
        let device = try FileBackedDevice(blockSize: 4096, blockCount: 2)
        try guardian.checkOpened(device, matches: disk(sizeBytes: 8192, blockSize: nil))
        #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)) {
            try guardian.checkOpened(device, matches: disk(sizeBytes: 8704, blockSize: nil))
        }
    }

    @Test func anUnknownSizeFailsClosed() throws {
        // Discovery falls back to 0 when diskutil reports no size.
        let device = try FileBackedDevice(blockSize: 512, blockCount: 16)
        #expect(throws: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)) {
            try guardian.checkOpened(device, matches: disk(sizeBytes: 0, blockSize: 512))
        }
    }
}

private struct StubDiscovery: DiskDiscovery {
    let disks: [DiskInfo]
    func listDisks() async throws -> [DiskInfo] { disks }
}

private struct CancelledDiscovery: DiskDiscovery {
    func listDisks() async throws -> [DiskInfo] { throw CancellationError() }
}

private struct StubResolver: BootDiskResolving {
    var boot = BootDiskSet.fixture
    func resolveBootDisks() async throws -> BootDiskSet { boot }
}

private struct FailingResolver: BootDiskResolving {
    func resolveBootDisks() async throws -> BootDiskSet {
        throw DiskDiscoveryError.bootDiskUnresolved(reason: "stub")
    }
}
