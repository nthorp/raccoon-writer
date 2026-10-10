import Foundation
import Testing
@testable import ImageWriterCore

struct ProgressDisplayTests {
    let image = ImageInfo(
        url: URL(fileURLWithPath: "/tmp/a.iso"), fileName: "a.iso", sizeBytes: 1000, kind: .iso,
        hasMBR: true, hasGPT: false, isISO9660: true, bootWarning: nil
    )

    @Test func nonRunningStatesHaveNoProgress() {
        let states: [WriteState] = [
            .idle, .imageSelected(image), .driveSelected(image, .usbStick()),
            .awaitingConfirmation(image, .usbStick()), .cancelled(.write),
            .failed(WriteFailure(stage: .write, error: CancellationError())),
        ]
        for state in states {
            #expect(ProgressDisplay(state: state, isCancelling: false) == nil)
        }
    }

    @Test func preparingIsIndeterminateAndNamesTheStage() throws {
        let check = try #require(ProgressDisplay(state: .preparing(.safetyCheck), isCancelling: false))
        #expect(check.title == "Checking the drive")
        #expect(check.fraction == nil && check.detail == nil)
        #expect(check.canCancel)
    }

    @Test func thePromptStageExplainsTheAuthopenDialog() throws {
        let open = try #require(ProgressDisplay(state: .preparing(.open), isCancelling: false))
        #expect(open.detail?.contains("authopen wants to make changes") == true)
    }

    @Test func writingShowsPercentBytesSpeedAndTimeLeft() throws {
        let progress = WriteProgress(completedBytes: 1_000_000_000, totalBytes: 4_000_000_000, bytesPerSecond: 20_000_000)
        let display = try #require(ProgressDisplay(state: .writing(progress), isCancelling: false))
        #expect(display.title == "Writing")
        #expect(display.fraction == 0.25)
        #expect(display.percentText == "25 %")
        #expect(display.bytesText == "1 GB of 4 GB")
        #expect(display.speedText == "20 MB/s")
        #expect(display.remainingText == "About 3 min left")
    }

    @Test func unknownSpeedShowsDashes() throws {
        let progress = WriteProgress(completedBytes: 0, totalBytes: 4_000, bytesPerSecond: nil)
        let display = try #require(ProgressDisplay(state: .verifying(progress), isCancelling: false))
        #expect(display.title == "Verifying")
        #expect(display.speedText == "—")
        #expect(display.remainingText == "—")
    }

    @Test func aCompleteWriteIsStillFlushing() throws {
        let progress = WriteProgress(completedBytes: 4_000, totalBytes: 4_000, bytesPerSecond: 1_000)
        let display = try #require(ProgressDisplay(state: .writing(progress), isCancelling: false))
        #expect(display.title == "Finishing the write")
        #expect(display.fraction == 1)
        #expect(display.speedText == nil && display.remainingText == nil)
        #expect(display.canCancel)
    }

    @Test func finishingCannotBeCancelled() throws {
        let display = try #require(ProgressDisplay(state: .finishing, isCancelling: false))
        #expect(!display.canCancel)
    }

    @Test func aRequestedCancelDisablesTheButton() throws {
        let progress = WriteProgress(completedBytes: 1, totalBytes: 4_000, bytesPerSecond: nil)
        let display = try #require(ProgressDisplay(state: .writing(progress), isCancelling: true))
        #expect(!display.canCancel)
        #expect(display.cancelTitle == "Cancelling…")
    }

    @Test func driveStateNoteFollowsWhetherTheDriveWasTouched() {
        for stage in PipelineStage.allCases {
            let note = stage.driveStateNote
            #expect(note.contains("partially written") == stage.mayHaveModifiedDrive)
            #expect(note.contains("Nothing was written") == !stage.mayHaveModifiedDrive)
        }
    }
}
