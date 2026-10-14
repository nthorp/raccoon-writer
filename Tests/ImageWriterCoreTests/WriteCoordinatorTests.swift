import Foundation
import Testing
@testable import ImageWriterCore

/// The T09 acceptance criteria, with every service faked. Each test gets its own temp
/// directory, removed in `deinit`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
final class WriteCoordinatorTests {
    nonisolated static let blockSize = 512
    nonisolated static let chunkBlocks = 4
    /// Three chunks and a bit, so cancels can land mid-pass.
    nonisolated static let imageBytes = 3 * chunkBlocks * blockSize + 100
    nonisolated static let deviceBlocks: UInt64 = 64

    let dir: URL
    let filter = DiskFilter(showAllExternal: false)
    /// The size of `device()`, which the opened device is checked against.
    let disk = DiskInfo.usbStick(sizeBytes: deviceBlocks * UInt64(blockSize))

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("raccoonwriter-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    func image(_ bytes: [UInt8] = pattern(count: imageBytes)) throws -> ImageInfo {
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).img")
        try Data(bytes).write(to: url)
        return try imageInfo(at: url)
    }

    func device(faults: FileBackedDevice.Faults = .init()) throws -> FileBackedDevice {
        try FileBackedDevice(blockSize: Self.blockSize, blockCount: Self.deviceBlocks, faults: faults)
    }

    func coordinator(
        listed: [DiskInfo]? = nil,
        discovery: (any DiskDiscovery)? = nil,
        diskManager: any DiskManager = FakeDiskManager(),
        opener: any DeviceOpener,
        clock: MonotonicClock = steppingClock(step: 0)
    ) -> (WriteCoordinator, StateLog) {
        let safetyGuard = SafetyGuard(
            discovery: discovery ?? StubDiscovery(disks: listed ?? [disk]),
            bootResolver: StubResolver()
        )
        let coordinator = WriteCoordinator(
            safetyGuard: safetyGuard,
            diskManager: diskManager,
            opener: opener,
            writeEngine: WriteEngine(chunkSize: Self.chunkBlocks * Self.blockSize, clock: steppingClock(step: 0)),
            verifier: Verifier(chunkSize: Self.chunkBlocks * Self.blockSize, clock: steppingClock(step: 0)),
            clock: clock
        )
        let log = StateLog()
        coordinator.onTransition = { log.states.append($0) }
        return (coordinator, log)
    }

    /// Selects an image and the drive and confirms, leaving the coordinator ready to start.
    func prepare(_ coordinator: WriteCoordinator, image: ImageInfo, drive: DiskInfo? = nil, filter: DiskFilter? = nil) throws {
        try coordinator.selectImage(image)
        try coordinator.selectDrive(drive ?? disk, filter: filter ?? self.filter)
        try coordinator.requestConfirmation()
    }

    /// Runs the pipeline to its end.
    func runToEnd(_ coordinator: WriteCoordinator, image: ImageInfo) async throws {
        try prepare(coordinator, image: image)
        try await coordinator.confirmAndStart().value
    }

    func failureIn(_ state: WriteState) -> WriteFailure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }

    // MARK: - Happy path

    @Test func happyPathStateSequence() async throws {
        let device = try device()
        let image = try image()
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: image)

        #expect(log.steps == [
            "imageSelected", "driveSelected", "awaitingConfirmation",
            "preparing(authorize)", "preparing(safetyCheck)", "preparing(unmount)", "preparing(open)",
            "writing", "verifying", "finishing", "finished",
        ])
        #expect(coordinator.isCancelling == false)
        #expect(coordinator.state.isRunning == false)
    }

    @Test func happyPathWritesTheImageClosesTheDeviceAndEjects() async throws {
        let bytes = pattern(count: Self.imageBytes)
        let device = try device()
        let opener = FakeDeviceOpener(device: device)
        let diskManager = FakeDiskManager()
        let probe = EjectProbe(inner: diskManager, device: device)
        let (coordinator, _) = coordinator(diskManager: probe, opener: opener)

        try await runToEnd(coordinator, image: try image(bytes))

        #expect(try device.contents().prefix(bytes.count) == Data(bytes))
        #expect(opener.authorizeAttempts == ["disk4"])
        #expect(opener.openAttempts == ["disk4"])
        #expect(opener.grants.map(\.releaseCount) == [1])
        #expect(diskManager.calls == [.unmount("disk4"), .eject("disk4")])
        #expect(device.syncCallCount == 1)
        #expect(device.closeCallCount >= 1)
        #expect(probe.deviceWasClosedAtEject == true)
    }

    @Test(arguments: [
        (FileBackedDevice.Faults(synchronizeSupported: true), SyncMethod.synchronize),
        (FileBackedDevice.Faults(fullFsyncUnsupported: true), SyncMethod.fsyncFallback),
    ])
    func summaryDescribesTheRun(faults: FileBackedDevice.Faults, method: SyncMethod) async throws {
        let device = try device(faults: faults)
        let image = try image()
        // Two coordinator clock reads, start and end, one second apart.
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: device), clock: steppingClock(step: 1))

        try await runToEnd(coordinator, image: image)

        #expect(coordinator.state == .finished(WriteSummary(
            imageName: image.fileName,
            driveName: "SanDisk Ultra",
            bsdName: "disk4",
            bytes: UInt64(Self.imageBytes),
            writeSeconds: 0,
            verifySeconds: 0,
            totalSeconds: 1,
            syncMethod: method,
            ejectWarning: nil
        )))
        #expect(coordinator.selectedImage == image)
        #expect(coordinator.selectedDrive == disk)
    }

    @Test func averageWriteSpeedComesFromTheWritePass() {
        var summary = WriteSummary(
            imageName: "a.iso", driveName: "Stick", bsdName: "disk4", bytes: 1000,
            writeSeconds: 4, verifySeconds: 2, totalSeconds: 7, syncMethod: .fullFsync, ejectWarning: nil
        )
        #expect(summary.averageWriteBytesPerSecond == 250)
        summary.writeSeconds = 0
        #expect(summary.averageWriteBytesPerSecond == nil)
    }

    @Test func progressNeverGoesBackwards() async throws {
        let device = try device()
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: try image())

        var writes: [UInt64] = []
        var verifies: [UInt64] = []
        for state in log.states {
            if case .writing(let progress) = state { writes.append(progress.completedBytes) }
            if case .verifying(let progress) = state { verifies.append(progress.completedBytes) }
        }
        #expect(writes.first == 0)
        #expect(verifies.first == 0)
        #expect(writes == writes.sorted())
        #expect(verifies == verifies.sorted())
    }

    @Test func ejectFailureFinishesWithAWarning() async throws {
        let device = try device()
        let diskManager = FakeDiskManager(ejectError: DiskManagerError.busy(dissenter: "/usr/bin/top"))
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: try image())

        guard case .finished(let summary) = coordinator.state else {
            Issue.record("Expected finished, got \(coordinator.state)")
            return
        }
        #expect(summary.ejectWarning?.bsdName == "disk4")
        #expect(device.isClosed)
    }

    @Test func driveListedOnlyUnderShowAllExternalIsWrittenUnderThatSetting() async throws {
        var ssd = disk
        ssd.busProtocol = "PCI-Express"
        let device = try device()
        let (coordinator, _) = coordinator(listed: [ssd], opener: FakeDeviceOpener(device: device))

        try prepare(coordinator, image: try image(), drive: ssd, filter: DiskFilter(showAllExternal: true))
        try await coordinator.confirmAndStart().value

        #expect(coordinator.state.phase == .finished)
    }

    // MARK: - Each stage failing

    @Test func safetyCheckFailureStopsBeforeUnmount() async throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(device: try device())
        let (coordinator, _) = coordinator(listed: [], diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .safetyCheck, error: SafetyGuardError.diskMissing(bsdName: "disk4"))))
        #expect(diskManager.calls.isEmpty)
        #expect(opener.openAttempts.isEmpty)
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    @Test func safetyCheckUsesTheFilterTheDriveWasSelectedUnder() async throws {
        var ssd = disk
        ssd.busProtocol = "PCI-Express"
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(listed: [ssd], diskManager: diskManager, opener: FakeDeviceOpener(device: try device()))

        try prepare(coordinator, image: try image(), drive: ssd, filter: DiskFilter(showAllExternal: false))
        try await coordinator.confirmAndStart().value

        #expect(coordinator.state == .failed(WriteFailure(
            stage: .safetyCheck,
            error: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .notUSB)
        )))
        #expect(diskManager.calls.isEmpty)
    }

    @Test func unmountFailureStopsBeforeOpen() async throws {
        let diskManager = FakeDiskManager(unmountError: DiskManagerError.busy(dissenter: "/bin/sleep"))
        let opener = FakeDeviceOpener(device: try device())
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: "/bin/sleep"))))
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(opener.openAttempts.isEmpty)
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    @Test func openFailureDoesNotEject() async throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(openError: .permissionDenied)
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .open, error: DeviceOpenError.permissionDenied)))
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    /// T25: same path as `.permissionDenied`; only the wording differs.
    @Test func privacyBlockedOpenDoesNotEject() async throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(openError: .blockedByPrivacySettings)
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .open, error: DeviceOpenError.blockedByPrivacySettings)))
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(opener.openAttempts == ["disk4"])
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    @Test func authorizationFailureStopsBeforeEverything() async throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(authorizeError: .authorizationFailed(status: errAuthorizationInternal))
        let (coordinator, log) = coordinator(diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(
            stage: .authorize,
            error: DeviceOpenError.authorizationFailed(status: errAuthorizationInternal)
        )))
        #expect(diskManager.calls.isEmpty)
        #expect(opener.openAttempts.isEmpty)
        #expect(!log.steps.contains("preparing(safetyCheck)"))
    }

    // MARK: - The drive changing hands during the password dialog

    @Test func aDifferentDiskThatTakesTheNameDuringThePromptIsRefused() async throws {
        // The stick is pulled while the dialog is up and a backup drive becomes disk4.
        var backup = disk
        backup.mediaName = "Backup HDD"
        backup.sizeBytes = 2_000_398_934_016
        backup.busProtocol = "PCI-Express"
        backup.isRemovable = false
        let discovery = SwappableDiscovery(disks: [disk])
        let replacement = backup
        let device = try device()
        let opener = FakeDeviceOpener(authorize: { _ in discovery.disks = [replacement] }, factory: { _ in device })
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(discovery: discovery, diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(
            stage: .safetyCheck,
            error: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)
        )))
        #expect(diskManager.calls.isEmpty)
        #expect(opener.openAttempts.isEmpty)
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    @Test func anOpenedDeviceOfAnotherSizeIsNeverWritten() async throws {
        // A disk that took the name between the safety check and the open.
        let other = try FileBackedDevice(blockSize: Self.blockSize, blockCount: Self.deviceBlocks * 2)
        let opener = FakeDeviceOpener(device: other)
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try await runToEnd(coordinator, image: try image())

        let failure = WriteFailure(stage: .open, error: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size))
        #expect(coordinator.state == .failed(failure))
        #expect(FailureExplanation(failure).drive == .untouched)
        #expect(other.writeCallCount == 0)
        #expect(other.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(opener.grants.map(\.releaseCount) == [1])
    }

    @Test func anOpenedDeviceWithAnotherBlockSizeIsNeverWritten() async throws {
        // Same byte count, different geometry.
        let other = try FileBackedDevice(blockSize: 4096, blockCount: Self.deviceBlocks / 8)
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: other))

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(
            stage: .open,
            error: SafetyGuardError.diskChanged(bsdName: "disk4", field: .blockSize)
        )))
        #expect(other.writeCallCount == 0)
        #expect(other.isClosed)
    }

    @Test func aCancelReportedByAuthopenItselfIsAFailureNotAPromptCancel() async throws {
        // Only the app's own dialog sends the user back to the confirm screen. If authopen
        // ever showed one, the drive is already unmounted, so the run fails plainly.
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(openError: .userCancelled))

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .open, error: DeviceOpenError.userCancelled)))
        #expect(coordinator.notice == nil)
    }

    @Test func writeFailureClosesTheDevice() async throws {
        let device = try device(faults: .init(failWrite: .init(call: 2, code: ENXIO)))
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: try image())

        let failure = try #require(failureIn(coordinator.state))
        #expect(failure.stage == .write)
        guard case WriteEngineError.write(.posix(_, ENXIO)) = failure.error else {
            Issue.record("Unexpected error \(failure.error)")
            return
        }
        #expect(device.isClosed)
        #expect(device.syncCallCount == 0)
        #expect(diskManager.calls == [.unmount("disk4")])
    }

    @Test func syncFailureIsAWriteFailure() async throws {
        let device = try device(faults: .init(syncError: EIO))
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: try image())

        let failure = try #require(failureIn(coordinator.state))
        #expect(failure.stage == .write)
        guard case WriteEngineError.sync = failure.error else {
            Issue.record("Unexpected error \(failure.error)")
            return
        }
        #expect(device.isClosed)
    }

    @Test func verifyReadFailureClosesTheDevice() async throws {
        let device = try device(faults: .init(failRead: .init(call: 2)))
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: device))

        try await runToEnd(coordinator, image: try image())

        let failure = try #require(failureIn(coordinator.state))
        #expect(failure.stage == .verify)
        guard case VerifierError.read(.posix(_, EIO)) = failure.error else {
            Issue.record("Unexpected error \(failure.error)")
            return
        }
        #expect(device.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
    }

    @Test func verifyMismatchIsReportedWithItsOffset() async throws {
        let device = try device()
        let corrupting = CorruptingDevice(inner: device, flipOffset: 700)
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: corrupting))

        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .verify, error: VerifierError.verificationFailed(atOffset: 700))))
        #expect(device.isClosed)
    }

    @Test func failureStagesSayWhetherTheDriveWasTouched() {
        #expect(PipelineStage.allCases.filter(\.mayHaveModifiedDrive) == [.write, .verify])
    }

    // MARK: - Cancel

    @Test func cancelDuringWriteStopsWithoutSyncOrEject() async throws {
        let inner = try device()
        let gated = GatedDevice(inner: inner, gatedWrite: 2)
        let diskManager = FakeDiskManager()
        let (coordinator, log) = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: gated))

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await gated.gate.waitForArrival()
        try coordinator.cancel()
        #expect(coordinator.isCancelling)
        gated.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.write))
        #expect(coordinator.isCancelling == false)
        #expect(inner.writeCallCount == 2)
        #expect(inner.syncCallCount == 0)
        #expect(inner.readCallCount == 0)
        #expect(inner.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(!log.steps.contains("verifying"))
    }

    @Test func cancelDuringVerifyStopsAndCloses() async throws {
        let inner = try device()
        let gated = GatedDevice(inner: inner, gatedRead: 2)
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: gated))

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await gated.gate.waitForArrival()
        try coordinator.cancel()
        gated.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.verify))
        #expect(inner.readCallCount == 2)
        #expect(inner.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
    }

    @Test func cancelWhileThePromptIsUpTouchesNothing() async throws {
        let device = try device()
        let inner = FakeDeviceOpener(device: device)
        let opener = GatedOpener(inner: inner, at: .authorize)
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await opener.gate.waitForArrival()
        #expect(coordinator.state == .preparing(.authorize))
        try coordinator.cancel()
        opener.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.authorize))
        #expect(diskManager.calls.isEmpty)
        #expect(inner.openAttempts.isEmpty)
        #expect(inner.grants.map(\.releaseCount) == [1])
    }

    @Test func cancelWhileOpeningClosesTheOpenedDevice() async throws {
        let device = try device()
        let inner = FakeDeviceOpener(device: device)
        let opener = GatedOpener(inner: inner, at: .open)
        let diskManager = FakeDiskManager()
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await opener.gate.waitForArrival()
        #expect(coordinator.state == .preparing(.open))
        try coordinator.cancel()
        opener.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.open))
        #expect(device.isClosed)
        #expect(device.writeCallCount == 0)
        #expect(diskManager.calls == [.unmount("disk4")])
        #expect(inner.grants.map(\.releaseCount) == [1])
    }

    @Test func promptCancelledAfterACancelRequestIsACancel() async throws {
        let opener = GatedOpener(inner: FakeDeviceOpener(authorizeError: .userCancelled), at: .authorize)
        let (coordinator, _) = coordinator(opener: opener)

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await opener.gate.waitForArrival()
        try coordinator.cancel()
        opener.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.authorize))
    }

    @Test func repeatedCancelIsHarmless() async throws {
        let inner = try device()
        let gated = GatedDevice(inner: inner, gatedWrite: 1)
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: gated))

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        await gated.gate.waitForArrival()
        try coordinator.cancel()
        try coordinator.cancel()
        gated.gate.release()
        await task.value

        #expect(coordinator.state == .cancelled(.write))
    }

    @Test func cancelOnTheConfirmScreenGoesBackToTheDriveStep() throws {
        let image = try image()
        let opener = FakeDeviceOpener(device: try device())
        let (coordinator, _) = coordinator(opener: opener)

        try prepare(coordinator, image: image)
        try coordinator.cancel()

        #expect(coordinator.state == .driveSelected(image, disk))
        #expect(opener.authorizeAttempts.isEmpty)
    }

    // MARK: - Legal transitions

    @Test func startWithoutConfirmationIsImpossible() throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(device: try device())
        let (coordinator, _) = coordinator(diskManager: diskManager, opener: opener)

        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .idle)) { try coordinator.confirmAndStart() }
        try coordinator.selectImage(try image())
        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .imageSelected)) { try coordinator.confirmAndStart() }
        try coordinator.selectDrive(disk, filter: filter)
        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .driveSelected)) { try coordinator.confirmAndStart() }
        try coordinator.requestConfirmation()
        try coordinator.cancel()
        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .driveSelected)) { try coordinator.confirmAndStart() }

        #expect(coordinator.state.phase == .driveSelected)
        #expect(diskManager.calls.isEmpty)
        #expect(opener.authorizeAttempts.isEmpty)
    }

    @Test func startIsAllowedOnlyOncePerConfirmation() async throws {
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))

        try prepare(coordinator, image: try image())
        let task = try coordinator.confirmAndStart()
        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .preparing)) { try coordinator.confirmAndStart() }
        await task.value
        #expect(throws: WriteCoordinatorError.notAllowed(.confirmAndStart, in: .finished)) { try coordinator.confirmAndStart() }
    }

    @Test func illegalCallsThrowAndChangeNothing() async throws {
        let image = try image()
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: try device()))

        #expect(throws: WriteCoordinatorError.notAllowed(.selectDrive, in: .idle)) { try coordinator.selectDrive(disk, filter: filter) }
        #expect(throws: WriteCoordinatorError.notAllowed(.requestConfirmation, in: .idle)) { try coordinator.requestConfirmation() }
        #expect(throws: WriteCoordinatorError.notAllowed(.cancel, in: .idle)) { try coordinator.cancel() }
        try coordinator.selectImage(image)
        #expect(throws: WriteCoordinatorError.notAllowed(.requestConfirmation, in: .imageSelected)) { try coordinator.requestConfirmation() }
        #expect(throws: WriteCoordinatorError.notAllowed(.cancel, in: .imageSelected)) { try coordinator.cancel() }
        try coordinator.selectDrive(disk, filter: filter)
        try coordinator.requestConfirmation()
        #expect(throws: WriteCoordinatorError.notAllowed(.selectImage, in: .awaitingConfirmation)) { try coordinator.selectImage(image) }
        #expect(throws: WriteCoordinatorError.notAllowed(.selectDrive, in: .awaitingConfirmation)) { try coordinator.selectDrive(disk, filter: filter) }
        #expect(coordinator.state == .awaitingConfirmation(image, disk))

        let task = try coordinator.confirmAndStart()
        #expect(throws: WriteCoordinatorError.notAllowed(.reset, in: .preparing)) { try coordinator.reset() }
        #expect(throws: WriteCoordinatorError.notAllowed(.selectImage, in: .preparing)) { try coordinator.selectImage(image) }
        await task.value
        #expect(throws: WriteCoordinatorError.notAllowed(.cancel, in: .finished)) { try coordinator.cancel() }
        #expect(log.steps.last == "finished")
    }

    @Test func resetAfterARunForgetsTheSelection() async throws {
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))

        try await runToEnd(coordinator, image: try image())
        try coordinator.reset()

        #expect(coordinator.state == .idle)
        #expect(coordinator.selectedImage == nil)
        #expect(coordinator.selectedDrive == nil)
        #expect(throws: WriteCoordinatorError.notAllowed(.selectDrive, in: .idle)) { try coordinator.selectDrive(disk, filter: filter) }
    }

    @Test func aSecondRunWorksAfterReset() async throws {
        let first = try device()
        let second = try device()
        let devices = DeviceQueue([first, second])
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener { _ in try devices.next() })

        try await runToEnd(coordinator, image: try image())
        try coordinator.reset()
        try await runToEnd(coordinator, image: try image())

        #expect(coordinator.state.phase == .finished)
        #expect(first.isClosed && second.isClosed)
    }

    @Test func choosingAnotherImageKeepsTheDrive() throws {
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))
        let first = try image()
        let second = try image()

        try coordinator.selectImage(first)
        try coordinator.selectDrive(disk, filter: filter)
        try coordinator.selectImage(second)

        #expect(coordinator.state == .driveSelected(second, disk))
        #expect(coordinator.selectedImage == second)
    }

    // MARK: - Image selection by URL

    @Test func selectingAFileInspectsIt() async throws {
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes[510] = 0x55
        bytes[511] = 0xAA
        let url = dir.appendingPathComponent("stick.img")
        try Data(bytes).write(to: url)

        let image = try await coordinator.selectImage(at: url)

        #expect(image.hasMBR)
        #expect(image.sizeBytes == 4096)
        #expect(coordinator.state == .imageSelected(image))
    }

    @Test func aRejectedFileLeavesTheStateAlone() async throws {
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: try device()))
        let url = dir.appendingPathComponent("notes.txt")
        try Data([1, 2, 3]).write(to: url)

        await #expect(throws: ImageInspectorError.self) { try await coordinator.selectImage(at: url) }

        #expect(coordinator.state == .idle)
        #expect(log.states.isEmpty)
    }

    // MARK: - Keeping the image

    @Test func resetKeepingTheImageReturnsToTheDriveStep() async throws {
        let image = try image()
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))

        try await runToEnd(coordinator, image: image)
        try coordinator.reset(keepingImage: true)

        #expect(coordinator.state == .imageSelected(image))
        #expect(coordinator.selectedImage == image)
        #expect(coordinator.selectedDrive == nil)
        // The drive must be picked again, so confirming straight away is impossible.
        #expect(throws: WriteCoordinatorError.notAllowed(.requestConfirmation, in: .imageSelected)) {
            try coordinator.requestConfirmation()
        }
    }

    @Test func resetKeepingTheImageAfterAFailureAllowsANewRun() async throws {
        let image = try image()
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(openError: .deviceBusy))

        try await runToEnd(coordinator, image: image)
        #expect(coordinator.state.phase == .failed)
        try coordinator.reset(keepingImage: true)
        try coordinator.selectDrive(disk, filter: filter)

        #expect(coordinator.state == .driveSelected(image, disk))
    }

    @Test func resetKeepingTheImageWithNoImageGoesIdle() throws {
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))

        try coordinator.reset(keepingImage: true)

        #expect(coordinator.state == .idle)
    }

    // MARK: - Drive list refresh

    @Test func refreshKeepsAStillListedDriveAndTakesItsFreshEntry() throws {
        let image = try image()
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: try device()))
        try coordinator.selectImage(image)
        try coordinator.selectDrive(disk, filter: filter)
        var remounted = disk
        remounted.mountPoints = ["/Volumes/OTHER"]

        coordinator.refreshSelectedDrive(from: [.usbStick("disk9"), disk], filter: filter)
        #expect(log.states.count == 2)
        coordinator.refreshSelectedDrive(from: [remounted], filter: filter)

        #expect(coordinator.state == .driveSelected(image, remounted))
        #expect(coordinator.selectedDrive == remounted)
    }

    @Test func refreshDeselectsADriveThatVanished() throws {
        let image = try image()
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))
        try coordinator.selectImage(image)
        try coordinator.selectDrive(disk, filter: filter)

        coordinator.refreshSelectedDrive(from: [.usbStick("disk9")], filter: filter)

        #expect(coordinator.state == .imageSelected(image))
        #expect(coordinator.selectedDrive == nil)
        #expect(throws: WriteCoordinatorError.notAllowed(.requestConfirmation, in: .imageSelected)) {
            try coordinator.requestConfirmation()
        }
    }

    @Test func refreshDeselectsADriveWhoseMediumChanged() throws {
        let image = try image()
        let (coordinator, _) = coordinator(opener: FakeDeviceOpener(device: try device()))
        try coordinator.selectImage(image)
        try coordinator.selectDrive(disk, filter: filter)
        var swapped = disk
        swapped.sizeBytes += 512

        coordinator.refreshSelectedDrive(from: [swapped], filter: filter)

        #expect(coordinator.state == .imageSelected(image))
    }

    @Test func refreshAdoptsTheNewListsFilterForTheSafetyCheck() async throws {
        // Picked under "Show all external disks", then the list is rebuilt under the
        // default setting while the drive is still in it: the safety check must use the
        // default filter, which rejects this non-USB disk.
        var thunderbolt = disk
        thunderbolt.busProtocol = "PCI-Express"
        let image = try image()
        let opener = FakeDeviceOpener(device: try device())
        let (coordinator, _) = coordinator(listed: [thunderbolt], opener: opener)
        try coordinator.selectImage(image)
        try coordinator.selectDrive(thunderbolt, filter: DiskFilter(showAllExternal: true))

        coordinator.refreshSelectedDrive(from: [thunderbolt], filter: DiskFilter(showAllExternal: false))
        try coordinator.requestConfirmation()
        try await coordinator.confirmAndStart().value

        #expect(coordinator.state == .failed(WriteFailure(
            stage: .safetyCheck,
            error: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .notUSB)
        )))
        #expect(opener.openAttempts.isEmpty)
    }

    @Test func refreshOutsideTheDriveStepChangesNothing() async throws {
        let image = try image()
        let (coordinator, log) = coordinator(opener: FakeDeviceOpener(device: try device()))
        coordinator.refreshSelectedDrive(from: [], filter: filter)
        try coordinator.selectImage(image)
        coordinator.refreshSelectedDrive(from: [], filter: filter)
        try coordinator.selectDrive(disk, filter: filter)
        try coordinator.requestConfirmation()
        let before = log.states.count

        coordinator.refreshSelectedDrive(from: [], filter: filter)

        #expect(coordinator.state == .awaitingConfirmation(image, disk))
        #expect(log.states.count == before)
    }

    // MARK: - Failure equality

    @Test func failuresCompareByStageAndError() {
        let busy = WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: nil))
        #expect(busy == WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: nil)))
        #expect(busy != WriteFailure(stage: .open, error: DiskManagerError.busy(dissenter: nil)))
        #expect(busy != WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: "/bin/sleep")))
        #expect(busy.message == DiskManagerError.busy(dissenter: nil).localizedDescription)
    }
}

// MARK: - Test doubles

/// Records the coordinator's states in order.
@MainActor
final class StateLog {
    var states: [WriteState] = []

    /// Phases with the preparing stage spelled out and consecutive repeats (progress
    /// updates) collapsed.
    var steps: [String] {
        var result: [String] = []
        for state in states {
            let step: String
            if case .preparing(let stage) = state {
                step = "preparing(\(stage.rawValue))"
            } else {
                step = state.phase.rawValue
            }
            if result.last != step { result.append(step) }
        }
        return result
    }
}

private struct StubDiscovery: DiskDiscovery {
    let disks: [DiskInfo]
    func listDisks() async throws -> [DiskInfo] { disks }
}

private struct StubResolver: BootDiskResolving {
    func resolveBootDisks() async throws -> BootDiskSet { .fixture }
}

/// Forwards to a `FakeDiskManager` and notes whether the device was already closed when
/// the eject ran.
private final class EjectProbe: DiskManager, @unchecked Sendable {
    let inner: FakeDiskManager
    let device: FileBackedDevice
    private let lock = NSLock()
    private var closedAtEject: Bool?

    init(inner: FakeDiskManager, device: FileBackedDevice) {
        self.inner = inner
        self.device = device
    }

    var deviceWasClosedAtEject: Bool? { lock.withLock { closedAtEject } }

    func unmountWholeDisk(bsdName: String) async throws {
        try await inner.unmountWholeDisk(bsdName: bsdName)
    }

    func eject(bsdName: String) async throws {
        let closed = device.isClosed
        lock.withLock { closedAtEject = closed }
        try await inner.eject(bsdName: bsdName)
    }
}

/// Lists whatever `disks` holds at the time of the query, so a test can swap the
/// drive while the password dialog is up.
private final class SwappableDiscovery: DiskDiscovery, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [DiskInfo]

    init(disks: [DiskInfo]) {
        current = disks
    }

    var disks: [DiskInfo] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func listDisks() async throws -> [DiskInfo] { disks }
}

/// Forwards to a `FakeDeviceOpener` but holds at `gate` first: in `authorize`, like the
/// password dialog being up, or in the grant's `open`, like authopen running.
private final class GatedOpener: DeviceOpener, @unchecked Sendable {
    enum Point { case authorize, open }

    let gate = Gate()
    let inner: FakeDeviceOpener
    let point: Point

    init(inner: FakeDeviceOpener, at point: Point) {
        self.inner = inner
        self.point = point
    }

    func authorize(bsdName: String) async throws -> any DeviceGrant {
        if point == .authorize { await gate.passOffThePool() }
        let grant = try await inner.authorize(bsdName: bsdName)
        return point == .open ? GatedGrant(inner: grant, gate: gate) : grant
    }
}

private final class GatedGrant: DeviceGrant, @unchecked Sendable {
    let inner: any DeviceGrant
    let gate: Gate

    init(inner: any DeviceGrant, gate: Gate) {
        self.inner = inner
        self.gate = gate
    }

    var bsdName: String { inner.bsdName }

    func open() async throws -> any OpenedDevice {
        await gate.passOffThePool()
        return try await inner.open()
    }

    func release() { inner.release() }
}

private extension Gate {
    /// `pass()` blocks its thread, so it runs on a GCD thread, not the cooperative pool.
    func passOffThePool() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.pass()
                continuation.resume()
            }
        }
    }
}

/// Forwards to a `FileBackedDevice` but stores one byte inverted, so the verify pass
/// finds a mismatch there.
private final class CorruptingDevice: OpenedDevice, @unchecked Sendable {
    let inner: FileBackedDevice
    let flipOffset: UInt64

    init(inner: FileBackedDevice, flipOffset: UInt64) {
        self.inner = inner
        self.flipOffset = flipOffset
    }

    var blockSize: Int { inner.blockSize }
    var blockCount: UInt64 { inner.blockCount }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        try inner.read(into: buffer, at: offset)
    }

    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        guard (offset..<offset + UInt64(buffer.count)).contains(flipOffset) else {
            return try inner.write(from: buffer, at: offset)
        }
        var copy = [UInt8](buffer)
        copy[Int(flipOffset - offset)] ^= 0xFF
        return try copy.withUnsafeBytes { try inner.write(from: $0, at: offset) }
    }

    func fullSync() throws -> SyncMethod { try inner.fullSync() }
    func close() { inner.close() }
}

/// Hands out the given devices one per open.
private final class DeviceQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [FileBackedDevice]

    init(_ devices: [FileBackedDevice]) {
        remaining = devices
    }

    func next() throws -> any OpenedDevice {
        try lock.withLock {
            guard !remaining.isEmpty else { throw DeviceOpenError.deviceBusy }
            return remaining.removeFirst()
        }
    }
}
