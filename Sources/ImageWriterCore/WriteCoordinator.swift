import Foundation
import Observation
import os

/// Drives the select → confirm → write → verify → eject flow and publishes it as
/// `state` for the UI to bind to. Every side effect is injected, so the whole flow
/// runs against fakes in tests and in the debug Simulate mode.
///
/// Main-actor isolated so SwiftUI can observe it directly; the slow work (diskutil,
/// authopen, device I/O) runs off the main thread inside the injected services.
@MainActor
@Observable
public final class WriteCoordinator {
    @ObservationIgnored private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "coordinator")

    public private(set) var state: WriteState = .idle
    /// The image and drive the current flow is about. They stay set during a run and
    /// its result, so the progress and done screens can name them.
    public private(set) var selectedImage: ImageInfo?
    public private(set) var selectedDrive: DiskInfo?
    /// True once the user asked to cancel a run, until it has stopped.
    public private(set) var isCancelling = false
    /// Set when a run returned to the confirm screen instead of failing; cleared by the
    /// next state change.
    public private(set) var notice: WriteNotice?

    @ObservationIgnored private let safetyGuard: SafetyGuard
    @ObservationIgnored private let diskManager: any DiskManager
    @ObservationIgnored private let opener: any DeviceOpener
    @ObservationIgnored private let writeEngine: WriteEngine
    @ObservationIgnored private let verifier: Verifier
    @ObservationIgnored private let inspector: ImageInspector
    @ObservationIgnored private let clock: MonotonicClock
    @ObservationIgnored private let sleepPreventer: any SleepPreventer

    /// The filter the selected drive was listed under; the safety check must use the same one.
    @ObservationIgnored private var selectedFilter: DiskFilter?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Identifies the current run, so a progress update hopping over from a finished
    /// run's I/O thread can't land in a later one.
    @ObservationIgnored private var runID: UInt64 = 0
    /// Test hook: called after every state change.
    @ObservationIgnored var onTransition: ((WriteState) -> Void)?

    /// The services that touch disks have no defaults, so a test can't reach diskutil
    /// or authopen by leaving one out. Use `live()` for the production wiring.
    public init(
        safetyGuard: SafetyGuard,
        diskManager: any DiskManager,
        opener: any DeviceOpener,
        writeEngine: WriteEngine = WriteEngine(),
        verifier: Verifier = Verifier(),
        inspector: ImageInspector = ImageInspector(),
        clock: MonotonicClock = .system,
        sleepPreventer: any SleepPreventer = ProcessInfoSleepPreventer()
    ) {
        self.safetyGuard = safetyGuard
        self.diskManager = diskManager
        self.opener = opener
        self.writeEngine = writeEngine
        self.verifier = verifier
        self.inspector = inspector
        self.clock = clock
        self.sleepPreventer = sleepPreventer
    }

    /// diskutil for the safety check and unmount/eject, authopen for the open.
    public static func live() -> WriteCoordinator {
        let runner = ProcessCommandRunner()
        return WriteCoordinator(
            safetyGuard: SafetyGuard(runner: runner),
            diskManager: DiskutilDiskManager(runner: runner),
            opener: AuthopenOpener()
        )
    }

    // MARK: - Selection

    /// Inspects the file off the main thread, then selects it. Throws
    /// `ImageInspectorError` for a file that can't be written, leaving the state as it was.
    @discardableResult
    public func selectImage(at url: URL) async throws -> ImageInfo {
        try requireImageSelectable()
        let inspector = self.inspector
        let image = try await Task.detached(priority: .userInitiated) { try inspector.inspect(url: url) }.value
        try selectImage(image)
        return image
    }

    /// Selects an image. A drive already selected stays selected.
    public func selectImage(_ image: ImageInfo) throws {
        try requireImageSelectable()
        selectedImage = image
        if let drive = selectedDrive {
            transition(to: .driveSelected(image, drive))
        } else {
            transition(to: .imageSelected(image))
        }
    }

    /// Selects a drive from a list built with `filter`. The safety check before the
    /// write re-applies that same filter.
    public func selectDrive(_ disk: DiskInfo, filter: DiskFilter) throws {
        guard let image = selectedImage, [.imageSelected, .driveSelected].contains(state.phase) else {
            throw notAllowed(.selectDrive)
        }
        selectedDrive = disk
        selectedFilter = filter
        transition(to: .driveSelected(image, disk))
    }

    /// Keeps the selected drive in step with a refreshed drive list built with `filter`.
    /// A drive still listed as the same medium is replaced by its fresh entry (mount
    /// points change) and adopts `filter`; one that vanished or changed identity is
    /// deselected. Only acts on the drive step; elsewhere the safety check covers it.
    public func refreshSelectedDrive(from drives: [DiskInfo], filter: DiskFilter) {
        guard case .driveSelected(let image, let selected) = state else { return }
        if let fresh = drives.first(where: { $0.bsdName == selected.bsdName }),
           fresh.identityDifference(from: selected) == nil {
            selectedFilter = filter
            if fresh != selected {
                selectedDrive = fresh
                transition(to: .driveSelected(image, fresh))
            }
        } else {
            selectedDrive = nil
            selectedFilter = nil
            transition(to: .imageSelected(image))
        }
    }

    /// Set on the drive step when the selected image is larger than the selected drive,
    /// which then can't be confirmed.
    public var driveTooSmall: DriveTooSmall? {
        guard case .driveSelected(let image, let disk) = state else { return nil }
        return DriveTooSmall(image: image, drive: disk)
    }

    /// Moves to the confirm screen. Only `confirmAndStart` can leave it towards a write.
    /// Throws `driveTooSmall` for an image that can't fit, so the user hears about it
    /// before being asked to erase anything.
    public func requestConfirmation() throws {
        guard case .driveSelected(let image, let disk) = state else { throw notAllowed(.requestConfirmation) }
        if let problem = DriveTooSmall(image: image, drive: disk) {
            throw WriteCoordinatorError.driveTooSmall(problem)
        }
        transition(to: .awaitingConfirmation(image, disk))
    }

    // MARK: - Running

    /// Starts the pipeline for the confirmed image and drive. Allowed only on the
    /// confirm screen. The returned task finishes once the run has reached a terminal
    /// state; the UI can ignore it.
    @discardableResult
    public func confirmAndStart() throws -> Task<Void, Never> {
        guard case .awaitingConfirmation(let image, let disk) = state, let filter = selectedFilter else {
            throw notAllowed(.confirmAndStart)
        }
        runID &+= 1
        let id = runID
        isCancelling = false
        let startTime = clock.now()
        transition(to: .preparing(.safetyCheck))
        let task = Task { await run(image: image, disk: disk, filter: filter, startTime: startTime, id: id) }
        runTask = task
        return task
    }

    /// On the confirm screen, goes back to the drive step. During a run, asks it to stop
    /// at the next safe point; the state becomes `.cancelled` once it has. Repeating the
    /// request is harmless. Not allowed while finishing: the drive is already verified.
    public func cancel() throws {
        switch state {
        case .awaitingConfirmation(let image, let disk):
            transition(to: .driveSelected(image, disk))
        case .preparing, .writing, .verifying:
            requestStop()
        default:
            throw notAllowed(.cancel)
        }
    }

    /// For quitting: cancels a run if one can still be stopped, then returns once it has
    /// ended, so the device is closed and the state final. A run that is already
    /// finishing (verified, ejecting) is left to complete. Returns at once if idle.
    /// While the admin prompt is up this waits for the user to answer it, since authopen
    /// can't be interrupted.
    public func stopAndWait() async {
        if state.cancellableStage != nil {
            requestStop()
        }
        await runTask?.value
    }

    private func requestStop() {
        guard !isCancelling else { return }
        isCancelling = true
        runTask?.cancel()
    }

    /// Back to the start, forgetting the drive. With `keepingImage` the selected image
    /// stays, for "Try again" and "Write another"; the drive is always picked afresh.
    /// Not allowed during a run.
    public func reset(keepingImage: Bool = false) throws {
        guard !state.isRunning else { throw notAllowed(.reset) }
        if !keepingImage {
            selectedImage = nil
        }
        selectedDrive = nil
        selectedFilter = nil
        runTask = nil
        isCancelling = false
        if let image = selectedImage {
            transition(to: .imageSelected(image))
        } else {
            transition(to: .idle)
        }
    }

    // MARK: - Pipeline

    private func run(image: ImageInfo, disk: DiskInfo, filter: DiskFilter, startTime: TimeInterval, id: UInt64) async {
        var stage = PipelineStage.safetyCheck
        var device: (any OpenedDevice)?
        // Every exit path, cancel and error included, releases the descriptor.
        defer { device?.close() }
        let activity = sleepPreventer.preventSleep(reason: "Writing \(image.fileName) to \(disk.bsdName)")
        defer { activity.end() }

        do {
            // The fresh disk, not the confirmed snapshot, is what gets unmounted and opened.
            let target = try await safetyGuard.validate(confirmed: disk, filter: filter)
            try Task.checkCancellation()

            stage = .unmount
            transition(to: .preparing(.unmount))
            try await diskManager.unmountWholeDisk(bsdName: target.bsdName)
            try Task.checkCancellation()

            stage = .open
            transition(to: .preparing(.open))
            // authopen honours a cancel only before its prompt appears; one that lands
            // while the prompt is up is caught by the check below, and the defer closes the fd.
            let opened = try await opener.openForReadWrite(bsdName: target.bsdName)
            device = opened
            try Task.checkCancellation()

            stage = .write
            transition(to: .writing(WriteProgress(completedBytes: 0, totalBytes: image.sizeBytes, bytesPerSecond: nil)))
            let written = try await writeEngine.write(image: image, to: opened) { [weak self] progress in
                Task { @MainActor in self?.apply(progress, to: .writing, id: id) }
            }

            stage = .verify
            transition(to: .verifying(VerifyProgress(completedBytes: 0, totalBytes: image.sizeBytes, bytesPerSecond: nil)))
            let verified = try await verifier.verify(image: image, against: opened) { [weak self] progress in
                Task { @MainActor in self?.apply(progress, to: .verifying, id: id) }
            }
            // A cancel that lands after the last compared chunk loses: every byte
            // matched, so reporting the drive as undefined would be wrong.

            transition(to: .finishing)
            opened.close()
            device = nil
            let warning = await diskManager.ejectAfterWrite(bsdName: target.bsdName)
            if let warning {
                Self.log.notice("Eject failed after a verified write: \(warning.reason, privacy: .public)")
            }
            finish(with: .finished(WriteSummary(
                imageName: image.fileName,
                driveName: disk.mediaName,
                bsdName: target.bsdName,
                bytes: written.bytesWritten,
                writeSeconds: written.elapsedSeconds,
                verifySeconds: verified.elapsedSeconds,
                totalSeconds: clock.now() - startTime,
                syncMethod: written.syncMethod,
                ejectWarning: warning
            )))
        } catch DeviceOpenError.userCancelled where stage == .open && !isCancelling {
            // Dismissing the password dialog is a change of mind, not a failure: back to
            // the confirm screen. The unmount before it succeeded, so no volumes are mounted.
            Self.log.notice("Admin prompt cancelled; back to the confirm screen")
            var unmounted = disk
            unmounted.mountPoints = []
            selectedDrive = unmounted
            transition(to: .awaitingConfirmation(image, unmounted))
            notice = .passwordPromptCancelled
        } catch {
            // Once the user has asked to stop, whatever unwinds the run (usually a
            // CancellationError, sometimes authopen's "canceled by the user") is a cancel.
            // The stage still tells the UI whether the drive was touched.
            if isCancelling || error is CancellationError {
                if !(error is CancellationError) {
                    Self.log.notice("Run cancelled in \(stage.rawValue, privacy: .public); it ended with: \(error.localizedDescription, privacy: .public)")
                }
                finish(with: .cancelled(stage))
            } else {
                Self.log.error("Run failed in \(stage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                finish(with: .failed(WriteFailure(stage: stage, error: error)))
            }
        }
    }

    private func finish(with result: WriteState) {
        isCancelling = false
        transition(to: result)
    }

    /// Progress hops from the I/O thread in its own task, so it can arrive after the
    /// pass ended or out of order; only a newer update for the current pass is applied.
    private func apply(_ progress: TransferProgress, to phase: WriteState.Phase, id: UInt64) {
        guard id == runID else { return }
        switch (phase, state) {
        case (.writing, .writing(let current)) where progress.completedBytes >= current.completedBytes:
            transition(to: .writing(progress))
        case (.verifying, .verifying(let current)) where progress.completedBytes >= current.completedBytes:
            transition(to: .verifying(progress))
        default:
            break
        }
    }

    // MARK: - Helpers

    private func requireImageSelectable() throws {
        guard [.idle, .imageSelected, .driveSelected].contains(state.phase) else { throw notAllowed(.selectImage) }
    }

    private func notAllowed(_ action: WriteCoordinatorError.Action) -> WriteCoordinatorError {
        .notAllowed(action, in: state.phase)
    }

    private func transition(to newState: WriteState) {
        notice = nil
        state = newState
        onTransition?(newState)
    }
}
