import Foundation
import Testing
@testable import ImageWriterCore

/// T11: every typed error the pipeline can throw maps to plain words and an honest
/// statement about the drive.
struct FailureExplanationTests {
    func explain(_ stage: PipelineStage, _ error: any Error) -> FailureExplanation {
        FailureExplanation(WriteFailure(stage: stage, error: error))
    }

    /// One failure per error case, at the stage that throws it.
    static let everyFailure: [WriteFailure] = [
        WriteFailure(stage: .safetyCheck, error: SafetyGuardError.diskMissing(bsdName: "disk4")),
        WriteFailure(stage: .safetyCheck, error: SafetyGuardError.diskChanged(bsdName: "disk4", field: .size)),
        WriteFailure(stage: .safetyCheck, error: SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .internalDisk)),
        WriteFailure(stage: .safetyCheck, error: SafetyGuardError.imageOnDrive(bsdName: "disk4", ImageOnDrive(fileName: "a.iso", mountPoint: "/Volumes/STICK"))),
        WriteFailure(stage: .safetyCheck, error: SafetyGuardError.queryFailed(reason: "diskutil timed out")),
        WriteFailure(stage: .safetyCheck, error: ImageSourceError.posix(operation: "open", fileName: "a.iso", code: ENOENT)),
        WriteFailure(stage: .unmount, error: DiskManagerError.invalidDiskName("disk4s1")),
        WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: "/Applications/Preview.app/Contents/MacOS/Preview")),
        WriteFailure(stage: .unmount, error: DiskManagerError.busy(dissenter: nil)),
        WriteFailure(stage: .unmount, error: DiskManagerError.notFound(bsdName: "disk4")),
        WriteFailure(stage: .unmount, error: DiskManagerError.commandFailed(command: "diskutil unmountDisk disk4", status: 1, output: "Unmount failed")),
        WriteFailure(stage: .unmount, error: CommandRunnerError.timedOut(executable: "/usr/sbin/diskutil", seconds: 60)),
        WriteFailure(stage: .open, error: DeviceOpenError.invalidDiskName("disk4s1")),
        WriteFailure(stage: .open, error: DeviceOpenError.userCancelled),
        WriteFailure(stage: .open, error: DeviceOpenError.permissionDenied),
        WriteFailure(stage: .open, error: DeviceOpenError.blockedByPrivacySettings),
        WriteFailure(stage: .open, error: DeviceOpenError.deviceBusy),
        WriteFailure(stage: .open, error: DeviceOpenError.authorizationFailed(status: -60008)),
        WriteFailure(stage: .open, error: DeviceOpenError.authopenFailed(status: 1, message: "boom")),
        WriteFailure(stage: .open, error: DeviceOpenError.authopenTerminated(signal: 9)),
        WriteFailure(stage: .open, error: DeviceOpenError.posix(operation: "recvmsg", code: EBADF)),
        WriteFailure(stage: .open, error: DeviceIOError.invalidGeometry(blockSize: 0, blockCount: 0)),
        WriteFailure(stage: .write, error: WriteEngineError.imageTooLarge(imageBytes: 4_000_000_000, deviceBytes: 2_000_000_000)),
        WriteFailure(stage: .write, error: WriteEngineError.write(.posix(operation: "write at offset 0", code: ENXIO))),
        WriteFailure(stage: .write, error: WriteEngineError.write(.posix(operation: "write at offset 0", code: ENODEV))),
        WriteFailure(stage: .write, error: WriteEngineError.write(.posix(operation: "write at offset 0", code: EIO))),
        WriteFailure(stage: .write, error: WriteEngineError.write(.posix(operation: "write at offset 0", code: ENOSPC))),
        WriteFailure(stage: .write, error: WriteEngineError.write(.closed)),
        WriteFailure(stage: .write, error: WriteEngineError.stalled(atOffset: 4096)),
        WriteFailure(stage: .write, error: WriteEngineError.partialBlock(atOffset: 4096, byteCount: 1792)),
        WriteFailure(stage: .write, error: WriteEngineError.sync(.posix(operation: "fsync", code: EIO))),
        WriteFailure(stage: .write, error: ImageSourceError.changed(fileName: "a.iso")),
        WriteFailure(stage: .write, error: ImageSourceError.truncated(fileName: "a.iso", atOffset: 10)),
        WriteFailure(stage: .write, error: ImageSourceError.posix(operation: "read", fileName: "a.iso", code: EIO)),
        WriteFailure(stage: .verify, error: VerifierError.imageTooLarge(imageBytes: 2, deviceBytes: 1)),
        WriteFailure(stage: .verify, error: VerifierError.read(.posix(operation: "read at offset 0", code: ENXIO))),
        WriteFailure(stage: .verify, error: VerifierError.read(.posix(operation: "read at offset 0", code: EIO))),
        WriteFailure(stage: .verify, error: VerifierError.deviceEnded(atOffset: 1_000_000)),
        WriteFailure(stage: .verify, error: VerifierError.partialBlock(atOffset: 4096, byteCount: 1792)),
        WriteFailure(stage: .verify, error: VerifierError.verificationFailed(atOffset: 8_388_608)),
        WriteFailure(stage: .verify, error: ImageSourceError.changed(fileName: "a.iso")),
    ]

    @Test(arguments: everyFailure)
    func everyFailureHasPlainWords(_ failure: WriteFailure) {
        let explanation = FailureExplanation(failure)
        #expect(!explanation.title.isEmpty)
        #expect(!explanation.message.isEmpty)
        // Technical text belongs in the details line, never the main message.
        for jargon in ["errno", "exit status", "authopen", "OSStatus", "posix", "recvmsg", "Optional(", "TCC", "EPERM"] {
            #expect(!explanation.message.contains(jargon), "\(failure.error) message: \(explanation.message)")
            #expect(!explanation.title.contains(jargon))
            // Remedy commands are meant to be technical; the words around them aren't.
            for remedy in explanation.remedies {
                for text in [remedy.title, remedy.instructions, remedy.note ?? ""] {
                    #expect(!text.contains(jargon), "\(failure.error) remedy: \(text)")
                }
            }
        }
    }

    @Test(arguments: everyFailure)
    func onlyAPrivacyBlockOffersRemediesAndTheSettingsButton(_ failure: WriteFailure) {
        let isPrivacyBlock = failure.error as? DeviceOpenError == .blockedByPrivacySettings
        let explanation = FailureExplanation(failure)
        #expect(explanation.action == (isPrivacyBlock ? .openFullDiskAccessSettings : nil))
        #expect(explanation.remedies.isEmpty == !isPrivacyBlock)
    }

    @Test(arguments: everyFailure)
    func stagesBeforeTheWriteNeverClaimTheDriveWasTouched(_ failure: WriteFailure) {
        let explanation = FailureExplanation(failure)
        if !failure.stage.mayHaveModifiedDrive {
            #expect(explanation.drive == .untouched)
        } else {
            #expect(explanation.drive != .untouched || failure.error is WriteEngineError)
        }
    }

    // MARK: - Drive removal

    @Test func removalMidWriteSaysDisconnectedAndPartiallyWritten() {
        for code in [ENXIO, ENODEV] {
            let explanation = explain(.write, WriteEngineError.write(.posix(operation: "write at offset 104857600", code: code)))
            #expect(explanation.title == "The drive was disconnected")
            #expect(explanation.message.contains("was not retried"))
            #expect(explanation.drive == .partiallyWritten)
            #expect(explanation.details?.contains("errno \(code)") == true)
        }
    }

    @Test func ioErrorMidWriteMayBeRemovalOrAFault() {
        let explanation = explain(.write, WriteEngineError.write(.posix(operation: "write", code: EIO)))
        #expect(explanation.title == "The drive stopped responding")
        #expect(explanation.message.contains("removed"))
        #expect(explanation.message.contains("faulty"))
        #expect(explanation.drive == .partiallyWritten)
    }

    @Test func removalDuringVerifyLeavesTheDriveUnverified() {
        let explanation = explain(.verify, VerifierError.read(.posix(operation: "read", code: ENXIO)))
        #expect(explanation.title == "The drive was disconnected")
        #expect(explanation.message.contains("verification"))
        #expect(explanation.drive == .unverified)
    }

    @Test func removalDuringTheFlushIsPartiallyWritten() {
        let explanation = explain(.write, WriteEngineError.sync(.posix(operation: "fcntl(F_FULLFSYNC)", code: ENXIO)))
        #expect(explanation.title == "The drive was disconnected")
        #expect(explanation.message.contains("final flush"))
        #expect(explanation.drive == .partiallyWritten)
    }

    @Test func otherSyncErrorsSayTheLastDataWasNotStored() {
        let explanation = explain(.write, WriteEngineError.sync(.posix(operation: "fsync", code: ENOTSUP)))
        #expect(explanation.title == "The drive reported an error")
        #expect(explanation.message.contains("failed to store"))
        #expect(explanation.drive == .partiallyWritten)
    }

    @Test func removalBeforeWritingSaysNothingWasWritten() {
        let missing = explain(.safetyCheck, SafetyGuardError.diskMissing(bsdName: "disk4"))
        #expect(missing.title == "The drive was disconnected")
        #expect(missing.drive == .untouched)
        let gone = explain(.unmount, DiskManagerError.notFound(bsdName: "disk4"))
        #expect(gone.title == "The drive was disconnected")
        #expect(gone.drive == .untouched)
    }

    // MARK: - Other mappings

    @Test func verificationMismatchSaysTheCopyIsWrongAndWhere() {
        let explanation = explain(.verify, VerifierError.verificationFailed(atOffset: 8_388_608))
        #expect(explanation.title == "Verification failed")
        #expect(explanation.message.contains("at byte 8388608 (8.4 MB in)"))
        #expect(explanation.drive == .doesNotMatch)
        #expect(explanation.details == nil)
    }

    @Test func partialBlockWriteSaysWritingStopped() {
        let explanation = explain(.write, WriteEngineError.partialBlock(atOffset: 8_388_608, byteCount: 1792))
        #expect(explanation.title == "The drive wrote only part of a block")
        #expect(explanation.message.contains("only part of a block at byte 8388608 (8.4 MB in)"))
        #expect(explanation.message.contains("writing was stopped"))
        #expect(explanation.drive == .partiallyWritten)
        #expect(explanation.details?.contains("1792 bytes") == true)
    }

    @Test func partialBlockReadSaysVerificationStopped() {
        let explanation = explain(.verify, VerifierError.partialBlock(atOffset: 8_388_608, byteCount: 1792))
        #expect(explanation.title == "The drive returned only part of a block")
        #expect(explanation.message.contains("verification was stopped"))
        #expect(explanation.drive == .unverified)
        #expect(explanation.details?.contains("1792 bytes") == true)
    }

    @Test func smallOffsetsAreNotGivenASize() {
        let explanation = explain(.verify, VerifierError.verificationFailed(atOffset: 700))
        #expect(explanation.message.contains("first at byte 700. "))
    }

    @Test func imageTooLargeAtTheWriteStageWroteNothing() {
        let explanation = explain(.write, WriteEngineError.imageTooLarge(imageBytes: 4_000_000_000, deviceBytes: 2_000_000_000))
        #expect(explanation.title == "The image is too large for this drive")
        #expect(explanation.message == "The image (4 GB) is larger than the drive (2 GB). Choose a drive of at least 4 GB.")
        #expect(explanation.drive == .untouched)
    }

    @Test func busyDriveNamesTheApp() {
        let explanation = explain(.unmount, DiskManagerError.busy(dissenter: "/Applications/Preview.app/Contents/MacOS/Preview"))
        #expect(explanation.title == "The drive is in use")
        #expect(explanation.message.contains("Preview"))
    }

    @Test func forbiddenTargetGivesTheReason() {
        let explanation = explain(.safetyCheck, SafetyGuardError.forbiddenTarget(bsdName: "disk4", reason: .notUSB))
        #expect(explanation.message == "/dev/disk4 was refused because it is not a USB drive. Turn on \"Show all external disks\" to use it.")
    }

    @Test func imageOnTheDriveSaysToCopyItFirst() {
        let problem = ImageOnDrive(fileName: "a.iso", mountPoint: "/Volumes/STICK")
        let explanation = explain(.safetyCheck, SafetyGuardError.imageOnDrive(bsdName: "disk4", problem))
        #expect(explanation.title == "The image is on this drive")
        #expect(explanation.message == problem.message)
        #expect(explanation.drive == .untouched)
    }

    /// The image is opened in the safety check, before the unmount, so one that went
    /// missing doesn't report a drive that was never written as partly written.
    @Test func imageMissingAtTheSafetyCheckLeavesTheDriveUntouched() {
        let explanation = explain(.safetyCheck, ImageSourceError.posix(operation: "open", fileName: "a.iso", code: ENOENT))
        #expect(explanation.title == "The image file couldn’t be read")
        #expect(explanation.drive == .untouched)
    }

    @Test func diskutilFailureKeepsItsOutputInTheDetails() {
        let explanation = explain(.unmount, DiskManagerError.commandFailed(command: "diskutil unmountDisk disk4", status: 1, output: "Unmount failed for disk4"))
        #expect(explanation.title == "The drive couldn’t be unmounted")
        #expect(explanation.details?.contains("Unmount failed for disk4") == true)
    }

    @Test func authopenFailuresKeepTheirDetails() {
        let explanation = explain(.open, DeviceOpenError.authopenFailed(status: 3, message: "no such device"))
        #expect(explanation.title == "The drive couldn’t be opened")
        #expect(explanation.details?.contains("exit status 3") == true)
        #expect(explanation.drive == .untouched)
    }

    /// T25: a denied Removable Volumes prompt, not the password.
    @Test func privacyBlockNamesTheSettingToChange() {
        let explanation = explain(.open, DeviceOpenError.blockedByPrivacySettings)
        #expect(explanation.title == "macOS blocked access to removable drives")
        #expect(explanation.message == "macOS privacy settings don’t allow Raccoon Writer to use removable drives, so the drive wasn’t opened. To fix this, do one of the following.")
        #expect(explanation.drive == .untouched)
        #expect(explanation.details == nil)
        #expect(explanation.action == .openFullDiskAccessSettings)
    }

    /// Files & Folders hides the Removable Volumes switch once macOS has added its own
    /// denied Full Disk Access entry, so neither fix sends people there.
    @Test func privacyBlockOffersATerminalResetThenFullDiskAccess() throws {
        let remedies = explain(.open, DeviceOpenError.blockedByPrivacySettings).remedies
        try #require(remedies.count == 2)

        let reset = remedies[0]
        #expect(reset.title == "Reset the permission in Terminal")
        #expect(reset.command == "tccutil reset SystemPolicyRemovableVolumes com.example.raccoonwriter")
        #expect(reset.instructions.contains("click Allow, then try again"))
        #expect(reset.instructions.contains("quit and reopen Raccoon Writer"))

        let fullDiskAccess = remedies[1]
        #expect(fullDiskAccess.title == "Turn on Full Disk Access")
        #expect(fullDiskAccess.instructions.contains("Privacy & Security › Full Disk Access, turn on Raccoon Writer"))
        #expect(fullDiskAccess.command == nil)
        #expect(fullDiskAccess.note == "Raccoon Writer doesn’t need full disk access, only access to removable drives, which Full Disk Access includes.")

        for remedy in remedies {
            #expect(!remedy.instructions.contains("Files & Folders"))
        }
    }

    @Test func refusedPermissionIsAboutThePasswordOnly() {
        let explanation = explain(.open, DeviceOpenError.permissionDenied)
        #expect(explanation.title == "Permission was refused")
        #expect(explanation.message.contains("administrator name and password"))
        #expect(!explanation.message.contains("macOS did not allow"))
        #expect(explanation.drive == .untouched)
    }

    @Test func authorizationFailureKeepsTheSystemMessageInTheDetails() {
        let explanation = explain(.open, DeviceOpenError.authorizationFailed(status: -60008))
        #expect(explanation.title == "The password couldn’t be checked")
        #expect(explanation.details?.contains("OSStatus -60008") == true)
        #expect(explanation.drive == .untouched)
    }

    @Test func imageFileErrorsDependOnTheStage() {
        #expect(explain(.write, ImageSourceError.changed(fileName: "a.iso")).drive == .partiallyWritten)
        #expect(explain(.verify, ImageSourceError.changed(fileName: "a.iso")).drive == .unverified)
        #expect(explain(.write, ImageSourceError.changed(fileName: "a.iso")).title == "The image file couldn’t be read")
    }

    @Test func unknownErrorsFallBackToTheStage() {
        struct Odd: Error {}
        let explanation = explain(.write, Odd())
        #expect(explanation.title == "The write failed")
        #expect(explanation.message == "Something went wrong while writing.")
        #expect(explanation.drive == .partiallyWritten)
        #expect(explanation.details != nil)

        #expect(explain(.unmount, Odd()).drive == .untouched)
        #expect(explain(.verify, Odd()).drive == .unverified)
    }

    // MARK: - Drive condition

    @Test func driveConditionByStage() {
        #expect(DriveCondition(stoppedIn: .safetyCheck) == .untouched)
        #expect(DriveCondition(stoppedIn: .unmount) == .untouched)
        #expect(DriveCondition(stoppedIn: .open) == .untouched)
        #expect(DriveCondition(stoppedIn: .write) == .partiallyWritten)
        #expect(DriveCondition(stoppedIn: .verify) == .unverified)
    }

    @Test func driveNotes() {
        #expect(DriveCondition.untouched.note == "Nothing was written to the drive.")
        #expect(DriveCondition.partiallyWritten.note.hasPrefix("The drive may be partially written and is not bootable."))
        #expect(DriveCondition.unverified.note.contains("could not be checked"))
        #expect(DriveCondition.doesNotMatch.note.contains("does not hold a correct copy"))
    }
}

extension WriteFailure: CustomTestStringConvertible {
    public var testDescription: String { "\(stage.rawValue): \(String(reflecting: error))" }
}
