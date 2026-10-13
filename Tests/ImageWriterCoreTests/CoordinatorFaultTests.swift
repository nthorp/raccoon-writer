import Foundation
import Testing
@testable import ImageWriterCore

/// T11: faults injected through the whole coordinator, checked down to what the failed
/// screen says, plus the prompt cancel, the too-small pre-check, sleep prevention and
/// stopping for quit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
final class CoordinatorFaultTests {
    nonisolated static let blockSize = 512
    nonisolated static let chunkBlocks = 4
    nonisolated static let imageBytes = 3 * chunkBlocks * blockSize + 100
    nonisolated static let deviceBlocks: UInt64 = 64

    let dir: URL
    let filter = DiskFilter(showAllExternal: false)
    /// The size of `device()`, which the opened device is checked against.
    let disk = DiskInfo.usbStick(sizeBytes: deviceBlocks * UInt64(blockSize))
    let sleep = FakeSleepPreventer()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("reddelicious-faults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    func image(bytes: Int = imageBytes) throws -> ImageInfo {
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).img")
        try Data(pattern(count: bytes)).write(to: url)
        return ImageInfo(
            url: url, fileName: url.lastPathComponent, sizeBytes: UInt64(bytes), kind: .img,
            hasMBR: false, hasGPT: false, isISO9660: false, bootWarning: nil
        )
    }

    func device(faults: FileBackedDevice.Faults = .init()) throws -> FileBackedDevice {
        try FileBackedDevice(blockSize: Self.blockSize, blockCount: Self.deviceBlocks, faults: faults, directory: dir)
    }

    func coordinator(diskManager: any DiskManager = FakeDiskManager(), opener: any DeviceOpener) -> WriteCoordinator {
        WriteCoordinator(
            safetyGuard: SafetyGuard(
                discovery: StaticDiskDiscovery(disks: [disk]),
                bootResolver: StaticBootDiskResolver(wholeDisks: ["disk0"])
            ),
            diskManager: diskManager,
            opener: opener,
            writeEngine: WriteEngine(chunkSize: Self.chunkBlocks * Self.blockSize, clock: steppingClock(step: 0)),
            verifier: Verifier(chunkSize: Self.chunkBlocks * Self.blockSize, clock: steppingClock(step: 0)),
            clock: steppingClock(step: 0),
            sleepPreventer: sleep
        )
    }

    func confirm(_ coordinator: WriteCoordinator, image: ImageInfo) throws {
        try coordinator.selectImage(image)
        try coordinator.selectDrive(disk, filter: filter)
        try coordinator.requestConfirmation()
    }

    func run(_ coordinator: WriteCoordinator, image: ImageInfo) async throws {
        try confirm(coordinator, image: image)
        try await coordinator.confirmAndStart().value
    }

    func explanation(_ coordinator: WriteCoordinator) throws -> FailureExplanation {
        guard case .failed(let failure) = coordinator.state else {
            throw Unexpected(state: coordinator.state)
        }
        return FailureExplanation(failure)
    }

    struct Unexpected: Error, CustomStringConvertible {
        let state: WriteState
        var description: String { "Expected a failure, got \(state)" }
    }

    // MARK: - Removal mid-write

    @Test func removalMidWriteStopsReportsAndNeverRetries() async throws {
        let device = try device(faults: .init(failWrite: .init(call: 2, code: ENXIO)))
        let opener = FakeDeviceOpener(device: device)
        let diskManager = FakeDiskManager()
        let coordinator = coordinator(diskManager: diskManager, opener: opener)

        try await run(coordinator, image: try image())

        let explanation = try explanation(coordinator)
        #expect(explanation.title == "The drive was disconnected")
        #expect(explanation.drive == .partiallyWritten)
        // Stopped at the failing write: no further writes, no flush, no verify, no eject.
        #expect(device.writeCallCount == 2)
        #expect(device.syncCallCount == 0)
        #expect(device.readCallCount == 0)
        #expect(device.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
        // One open, of the confirmed disk, and nothing queued for another.
        #expect(opener.openAttempts == ["disk4"])
        try coordinator.reset(keepingImage: true)
        #expect(coordinator.selectedDrive == nil)
        #expect(throws: WriteCoordinatorError.notAllowed(.requestConfirmation, in: .imageSelected)) {
            try coordinator.requestConfirmation()
        }
        #expect(opener.openAttempts == ["disk4"])
    }

    @Test func ioErrorMidVerifyIsReportedAsUnverified() async throws {
        let device = try device(faults: .init(failRead: .init(call: 2, code: EIO)))
        let coordinator = coordinator(opener: FakeDeviceOpener(device: device))

        try await run(coordinator, image: try image())

        let explanation = try explanation(coordinator)
        #expect(explanation.title == "The drive stopped responding")
        #expect(explanation.drive == .unverified)
        #expect(device.isClosed)
    }

    // MARK: - Sync failure

    @Test func syncFailureIsReportedAsPartiallyWritten() async throws {
        let device = try device(faults: .init(syncError: EIO))
        let diskManager = FakeDiskManager()
        let coordinator = coordinator(diskManager: diskManager, opener: FakeDeviceOpener(device: device))

        try await run(coordinator, image: try image())

        let explanation = try explanation(coordinator)
        #expect(explanation.message.contains("final flush"))
        #expect(explanation.drive == .partiallyWritten)
        #expect(device.readCallCount == 0)
        #expect(device.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
    }

    // MARK: - Verification mismatch

    @Test func verificationMismatchIsReportedWithItsOffset() async throws {
        let inner = try device()
        let opener = FakeDeviceOpener(device: BitFlippingDevice(inner: inner, flipOffset: 5000))
        let diskManager = FakeDiskManager()
        let coordinator = coordinator(diskManager: diskManager, opener: opener)

        try await run(coordinator, image: try image())

        let explanation = try explanation(coordinator)
        #expect(explanation.title == "Verification failed")
        #expect(explanation.message.contains("at byte 5000 (5 KB in)"))
        #expect(explanation.drive == .doesNotMatch)
        #expect(inner.isClosed)
        #expect(diskManager.calls == [.unmount("disk4")])
    }

    // MARK: - Prompt cancelled

    @Test func cancelledPromptReturnsToTheConfirmScreenWithTheDriveUntouched() async throws {
        let diskManager = FakeDiskManager()
        let opener = FakeDeviceOpener(authorizeError: .userCancelled)
        let coordinator = coordinator(diskManager: diskManager, opener: opener)
        let image = try image()

        try await run(coordinator, image: image)

        // The dialog comes before the unmount, so the volumes stay mounted.
        #expect(coordinator.state == .awaitingConfirmation(image, disk))
        #expect(coordinator.notice == .passwordPromptCancelled)
        #expect(coordinator.selectedDrive == disk)
        #expect(coordinator.isCancelling == false)
        #expect(diskManager.calls.isEmpty)
        #expect(opener.authorizeAttempts == ["disk4"])
        #expect(opener.openAttempts.isEmpty)
    }

    @Test func afterACancelledPromptTheUserCanConfirmAgain() async throws {
        let device = try device()
        let attempts = AttemptCounter()
        let opener = FakeDeviceOpener(authorize: { _ in
            if attempts.next() == 1 { throw DeviceOpenError.userCancelled }
        }) { _ in device }
        let coordinator = coordinator(opener: opener)

        try await run(coordinator, image: try image())
        #expect(coordinator.state.phase == .awaitingConfirmation)
        try await coordinator.confirmAndStart().value

        #expect(coordinator.state.phase == .finished)
        #expect(coordinator.notice == nil)
        #expect(device.isClosed)
    }

    @Test func afterACancelledPromptTheUserCanGoBack() async throws {
        let coordinator = coordinator(opener: FakeDeviceOpener(authorizeError: .userCancelled))
        let image = try image()

        try await run(coordinator, image: image)
        try coordinator.cancel()

        #expect(coordinator.state.phase == .driveSelected)
        #expect(coordinator.notice == nil)
    }

    @Test func otherOpenFailuresStillFail() async throws {
        let coordinator = coordinator(opener: FakeDeviceOpener(authorizeError: .permissionDenied))

        try await run(coordinator, image: try image())

        #expect(coordinator.state == .failed(WriteFailure(stage: .authorize, error: DeviceOpenError.permissionDenied)))
        #expect(coordinator.notice == nil)
    }

    // MARK: - Image too large

    @Test func aDriveTooSmallIsReportedBeforeConfirmation() throws {
        let opener = FakeDeviceOpener(device: try device())
        let coordinator = coordinator(opener: opener)
        var small = disk
        small.sizeBytes = UInt64(Self.imageBytes - 1)
        let image = try image()

        try coordinator.selectImage(image)
        #expect(coordinator.driveTooSmall == nil)
        try coordinator.selectDrive(small, filter: filter)

        let expected = DriveTooSmall(imageBytes: UInt64(Self.imageBytes), driveBytes: UInt64(Self.imageBytes - 1))
        #expect(coordinator.driveTooSmall == expected)
        #expect(throws: WriteCoordinatorError.driveTooSmall(expected)) { try coordinator.requestConfirmation() }
        #expect(coordinator.state == .driveSelected(image, small))
        #expect(opener.authorizeAttempts.isEmpty)
    }

    @Test func choosingASmallerImageClearsTheProblem() throws {
        let coordinator = coordinator(opener: FakeDeviceOpener(device: try device()))
        var small = disk
        small.sizeBytes = 4096

        try coordinator.selectImage(try image(bytes: 8192))
        try coordinator.selectDrive(small, filter: filter)
        #expect(coordinator.driveTooSmall != nil)
        try coordinator.selectImage(try image(bytes: 4096))

        #expect(coordinator.driveTooSmall == nil)
        try coordinator.requestConfirmation()
        #expect(coordinator.state.phase == .awaitingConfirmation)
    }

    @Test func driveTooSmallCheck() throws {
        let image = try image(bytes: 1000)
        var drive = disk
        drive.sizeBytes = 1000
        #expect(DriveTooSmall(image: image, drive: drive) == nil)
        drive.sizeBytes = 999
        #expect(DriveTooSmall(image: image, drive: drive) == DriveTooSmall(imageBytes: 1000, driveBytes: 999))
        #expect(DriveTooSmall(imageBytes: 4_700_000_000, driveBytes: 4_000_000_000).message
            == "The image (4.7 GB) is larger than the drive (4 GB). Choose a drive of at least 4.7 GB.")
    }

    // MARK: - Sleep prevention

    @Test func sleepIsPreventedForTheWholeRunOnly() async throws {
        let device = try device()
        let gated = GatedDevice(inner: device, gatedWrite: 1)
        let coordinator = coordinator(opener: FakeDeviceOpener(device: gated))
        let image = try image()

        try confirm(coordinator, image: image)
        #expect(sleep.reasons.isEmpty)
        let task = try coordinator.confirmAndStart()
        await gated.gate.waitForArrival()
        #expect(sleep.activeCount == 1)
        gated.gate.release()
        await task.value

        #expect(coordinator.state.phase == .finished)
        #expect(sleep.reasons == ["Writing \(image.fileName) to disk4"])
        #expect(sleep.activeCount == 0)
    }

    @Test func sleepIsAllowedAgainAfterEveryKindOfEnd() async throws {
        let failing = coordinator(opener: FakeDeviceOpener(device: try device(faults: .init(failWrite: .init(call: 1)))))
        try await run(failing, image: try image())
        #expect(failing.state.phase == .failed)

        let prompt = coordinator(opener: FakeDeviceOpener(authorizeError: .userCancelled))
        try await run(prompt, image: try image())
        #expect(prompt.state.phase == .awaitingConfirmation)

        let gated = GatedDevice(inner: try device(), gatedWrite: 1)
        let cancelled = coordinator(opener: FakeDeviceOpener(device: gated))
        try confirm(cancelled, image: try image())
        let task = try cancelled.confirmAndStart()
        await gated.gate.waitForArrival()
        try cancelled.cancel()
        gated.gate.release()
        await task.value
        #expect(cancelled.state.phase == .cancelled)

        #expect(sleep.reasons.count == 3)
        #expect(sleep.activeCount == 0)
    }

    @Test func processInfoActivityCanBeEndedTwice() {
        let activity = ProcessInfoSleepPreventer().preventSleep(reason: "Red Delicious unit test")
        activity.end()
        activity.end()
    }

    // MARK: - Stopping for quit

    @Test func stopAndWaitCancelsAWriteAndReturnsOnceClosed() async throws {
        let device = try device()
        let gated = GatedDevice(inner: device, gatedWrite: 2)
        let coordinator = coordinator(opener: FakeDeviceOpener(device: gated))
        try confirm(coordinator, image: try image())
        _ = try coordinator.confirmAndStart()
        await gated.gate.waitForArrival()

        let stopper = Task { await coordinator.stopAndWait() }
        // Bounded, so a stopAndWait that never cancels fails instead of hanging.
        for _ in 0..<1000 where !coordinator.isCancelling { await Task.yield() }
        #expect(coordinator.isCancelling)
        gated.gate.release()
        await stopper.value

        #expect(coordinator.state == .cancelled(.write))
        #expect(device.isClosed)
        #expect(sleep.activeCount == 0)
    }

    @Test func stopAndWaitLetsAFinishingRunComplete() async throws {
        let device = try device()
        let ejectGate = GatedEjectManager()
        let coordinator = coordinator(diskManager: ejectGate, opener: FakeDeviceOpener(device: device))
        try confirm(coordinator, image: try image())
        _ = try coordinator.confirmAndStart()
        await ejectGate.gate.waitForArrival()
        #expect(coordinator.state == .finishing)

        let stopper = Task {
            await coordinator.stopAndWait()
            return coordinator.state
        }
        // Let the stopper reach its wait; returning early would still show .finishing.
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.isCancelling == false)
        ejectGate.gate.release()

        #expect(await stopper.value.phase == .finished)
    }

    @Test func stopAndWaitWithNoRunReturnsAtOnce() async throws {
        let coordinator = coordinator(opener: FakeDeviceOpener(device: try device()))
        await coordinator.stopAndWait()
        #expect(coordinator.state == .idle)
    }

    @Test func cancellableStages() throws {
        let image = try image()
        let progress = TransferProgress(completedBytes: 0, totalBytes: 1, bytesPerSecond: nil)
        #expect(WriteState.preparing(.authorize).cancellableStage == .authorize)
        #expect(WriteState.preparing(.open).cancellableStage == .open)
        #expect(WriteState.writing(progress).cancellableStage == .write)
        #expect(WriteState.verifying(progress).cancellableStage == .verify)
        #expect(WriteState.finishing.cancellableStage == nil)
        #expect(WriteState.awaitingConfirmation(image, disk).cancellableStage == nil)
        #expect(WriteState.cancelled(.write).cancellableStage == nil)
    }
}

// MARK: - Test doubles

/// Counts calls from any thread, starting at 1.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Unmounts at once, but holds the eject at `gate`, so a test can act while the
/// coordinator is finishing.
private final class GatedEjectManager: DiskManager, @unchecked Sendable {
    let gate = Gate()

    func unmountWholeDisk(bsdName: String) async throws {}

    func eject(bsdName: String) async throws {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.gate.pass()
                continuation.resume()
            }
        }
    }
}

/// Forwards to a `FileBackedDevice` but returns one byte inverted on read-back.
private final class BitFlippingDevice: OpenedDevice, @unchecked Sendable {
    let inner: FileBackedDevice
    let flipOffset: UInt64

    init(inner: FileBackedDevice, flipOffset: UInt64) {
        self.inner = inner
        self.flipOffset = flipOffset
    }

    var blockSize: Int { inner.blockSize }
    var blockCount: UInt64 { inner.blockCount }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = try inner.read(into: buffer, at: offset)
        if flipOffset >= offset, flipOffset < offset + UInt64(count) {
            buffer[Int(flipOffset - offset)] ^= 0xFF
        }
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try inner.write(from: buffer, at: offset)
    }

    func fullSync() throws -> SyncMethod { try inner.fullSync() }
    func close() { inner.close() }
}
