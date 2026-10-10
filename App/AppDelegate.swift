import AppKit
import ImageWriterCore

/// Guards quitting during a run. Quitting is allowed, but only after the user agrees
/// and the run has stopped cleanly, so the device is always closed by the coordinator
/// rather than by the process dying.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isQuitting = false

    // One window: closing it (outside a run, see WindowCloseGuard) quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = AppServices.shared.coordinator
        guard coordinator.state.isRunning else { return .terminateNow }
        // A second ⌘Q while the first is waiting for the run to stop.
        guard !isQuitting else { return .terminateCancel }
        // Ejecting after a verified write: nothing to ask, just let it finish.
        if let stage = coordinator.state.cancellableStage, !confirmStop(in: stage) {
            return .terminateCancel
        }
        isQuitting = true
        Task {
            await coordinator.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmStop(in stage: PipelineStage) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = stage.mayHaveModifiedDrive ? "Stop writing and quit?" : "Cancel and quit?"
        var info = DriveCondition(stoppedIn: stage).note
        if stage == .open {
            info += " If the password dialog is open, ISO Sword quits once you answer it."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Keep Writing")
        let quit = alert.addButton(withTitle: "Stop and Quit")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
