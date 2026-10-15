import SwiftUI
import os
import ImageWriterCore

/// Shows the screen for the coordinator's state and forwards button presses to it.
/// All decisions live in `WriteCoordinator` and `DriveListModel`.
struct ContentView: View {
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "ui")

    let coordinator: WriteCoordinator
    let driveList: DriveListModel
    let isSimulation: Bool

    @State private var isPickingImage = false
    @State private var imageError: String?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
#if DEBUG
            if isSimulation {
                SimulationBanner()
            }
#endif
            step
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 540, idealWidth: 580, maxWidth: 760, minHeight: 460, idealHeight: 500, maxHeight: 900)
        .background(WindowCloseGuard(isBlocked: coordinator.state.isRunning))
        .fileImporter(isPresented: $isPickingImage, allowedContentTypes: ImageFileTypes.allowed) { result in
            switch result {
            case .success(let url):
                selectImage(at: url)
            case .failure(let error):
                imageError = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var step: some View {
        switch coordinator.state {
        case .idle, .imageSelected, .driveSelected:
            SetupView(
                image: coordinator.selectedImage,
                imageError: imageError,
                selectedDrive: coordinator.state.phase == .driveSelected ? coordinator.selectedDrive : nil,
                driveTooSmall: coordinator.driveTooSmall,
                imageOnDrive: coordinator.imageOnDrive,
                drives: driveList.drives,
                hasLoadedDrives: driveList.hasLoaded,
                driveListError: driveList.errorMessage,
                showAllExternal: Binding(
                    get: { driveList.showAllExternal },
                    set: { value in Task { await driveList.setShowAllExternal(value) } }
                ),
                onChooseImage: { isPickingImage = true },
                onSelectDrive: { disk in perform { try coordinator.selectDrive(disk, filter: driveList.filter) } },
                onRefreshDrives: { Task { await driveList.refresh() } },
                onContinue: { perform { try coordinator.requestConfirmation() } }
            )
            // Polls only while this screen is up; the safety check re-queries before writing.
            .task { await driveList.autoRefresh() }

        case .awaitingConfirmation(let image, let disk):
            ConfirmView(
                image: image,
                disk: disk,
                notice: coordinator.notice,
                onCancel: { perform { try coordinator.cancel() } },
                onConfirm: { perform { try coordinator.confirmAndStart() } }
            )

        case .preparing, .writing, .verifying, .finishing:
            ProgressStepView(
                state: coordinator.state,
                isCancelling: coordinator.isCancelling,
                imageName: coordinator.selectedImage?.fileName,
                driveName: coordinator.selectedDrive?.mediaName,
                onCancel: { perform { try coordinator.cancel() } }
            )

        case .finished(let summary):
            DoneView(summary: summary, onWriteAnother: startAgain)

        case .failed(let failure):
            FailedView(failure: failure, onTryAgain: startAgain)

        case .cancelled(let stage):
            CancelledView(stage: stage, onStartAgain: startAgain)
        }
    }

    // MARK: - Actions

    private func selectImage(at url: URL) {
        Task {
            do {
                try await coordinator.selectImage(at: url)
                imageError = nil
            } catch {
                imageError = error.localizedDescription
            }
        }
    }

    /// Back to the drive step with the same image; the drive is always chosen afresh.
    private func startAgain() {
        perform { try coordinator.reset(keepingImage: true) }
    }

    /// Coordinator calls only throw for a call the current state doesn't allow, which
    /// the screens are built to prevent. Shown rather than swallowed, in case one slips through.
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            Self.log.error("UI action refused: \(error.localizedDescription, privacy: .public)")
            actionError = error.localizedDescription
        }
    }
}
