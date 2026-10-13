import Foundation

/// What the failed screen says about a `WriteFailure`: a headline, a plain-language
/// explanation, what happened to the drive, and the technical text when it adds
/// something (errno, diskutil output). Every typed error the pipeline throws has its
/// own wording; anything else falls back to the stage and the error's description.
public struct FailureExplanation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var drive: DriveCondition
    /// The raw error text, for a details line. Nil when the message already says it all.
    public var details: String?

    public init(title: String, message: String, drive: DriveCondition, details: String? = nil) {
        self.title = title
        self.message = message
        self.drive = drive
        self.details = details
    }

    public init(_ failure: WriteFailure) {
        let stage = failure.stage
        let error = failure.error
        switch error {
        case let error as SafetyGuardError:
            self = Self.explain(error)
        case let error as DiskManagerError:
            self = Self.explain(error)
        case let error as DeviceOpenError:
            self = Self.explain(error)
        case let error as WriteEngineError:
            self = Self.explain(error)
        case let error as VerifierError:
            self = Self.explain(error)
        case let error as ImageSourceError:
            self = Self.explain(error, stage: stage)
        case let error as DeviceIOError:
            self = Self.explain(error, stage: stage)
        case let error as CommandRunnerError:
            self = Self.explain(error, stage: stage)
        default:
            self = Self.fallback(error, stage: stage)
        }
        // A stage that never reaches the drive can't have changed it, whatever the error.
        if !stage.mayHaveModifiedDrive {
            drive = .untouched
        }
    }

    // MARK: - Safety check

    private static func explain(_ error: SafetyGuardError) -> FailureExplanation {
        switch error {
        case .diskMissing:
            return FailureExplanation(
                title: "The drive was disconnected",
                message: "The drive can no longer be found. It may have been removed before writing started.",
                drive: .untouched
            )
        case .diskChanged(let bsdName, let field):
            return FailureExplanation(
                title: "A different drive is attached",
                message: "The drive at /dev/\(bsdName) is not the one you confirmed: its \(field.label) changed. Select the drive again.",
                drive: .untouched
            )
        case .forbiddenTarget(let bsdName, let reason):
            return FailureExplanation(
                title: "This drive can’t be written",
                message: "/dev/\(bsdName) was refused because \(reason.explanation)",
                drive: .untouched
            )
        case .queryFailed(let reason):
            return FailureExplanation(
                title: "The drive couldn’t be checked",
                message: "The disks could not be checked again just before writing, so the write was not started.",
                drive: .untouched,
                details: reason
            )
        }
    }

    // MARK: - Unmount

    private static func explain(_ error: DiskManagerError) -> FailureExplanation {
        switch error {
        case .busy:
            return FailureExplanation(
                title: "The drive is in use",
                message: error.localizedDescription,
                drive: .untouched
            )
        case .notFound:
            return FailureExplanation(
                title: "The drive was disconnected",
                message: "The drive can no longer be found. It may have been removed before writing started.",
                drive: .untouched
            )
        case .invalidDiskName, .commandFailed:
            return FailureExplanation(
                title: "The drive couldn’t be unmounted",
                message: "macOS could not unmount the drive’s volumes. Eject them in Finder, then try again.",
                drive: .untouched,
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Admin prompt and open

    private static func explain(_ error: DeviceOpenError) -> FailureExplanation {
        switch error {
        case .userCancelled:
            return FailureExplanation(
                title: "Permission was not given",
                message: "The administrator password dialog was cancelled.",
                drive: .untouched
            )
        case .permissionDenied:
            return FailureExplanation(
                title: "Permission was refused",
                message: "macOS did not allow the drive to be opened for writing. Use the name and password of an administrator account.",
                drive: .untouched
            )
        case .deviceBusy:
            return FailureExplanation(
                title: "The drive is in use",
                message: "Another app is still using the drive. Quit any app that may be using it, then try again.",
                drive: .untouched
            )
        case .authorizationFailed:
            return FailureExplanation(
                title: "The password couldn’t be checked",
                message: "macOS could not check the administrator password, so the drive was not opened. Try again, and restart the Mac if it keeps happening.",
                drive: .untouched,
                details: error.localizedDescription
            )
        case .invalidDiskName, .authopenFailed, .authopenTerminated, .posix:
            return FailureExplanation(
                title: "The drive couldn’t be opened",
                message: "macOS could not open the drive for writing.",
                drive: .untouched,
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Write

    private static func explain(_ error: WriteEngineError) -> FailureExplanation {
        switch error {
        case .imageTooLarge(let imageBytes, let deviceBytes):
            // Checked before the first write.
            return FailureExplanation(
                title: "The image is too large for this drive",
                message: DriveTooSmall(imageBytes: imageBytes, driveBytes: deviceBytes).message,
                drive: .untouched
            )
        case .write(let ioError):
            return deviceError(ioError, during: "the write", otherwise: "Writing to the drive failed.", drive: .partiallyWritten)
        case .stalled(let offset):
            return FailureExplanation(
                title: "The drive stopped accepting data",
                message: "The drive stopped accepting data \(position(offset)). It may be faulty.",
                drive: .partiallyWritten
            )
        case .sync(let ioError):
            return deviceError(
                ioError,
                during: "the final flush",
                otherwise: "All of the image was sent, but the drive failed to store the last of it.",
                drive: .partiallyWritten
            )
        }
    }

    // MARK: - Verify

    private static func explain(_ error: VerifierError) -> FailureExplanation {
        switch error {
        case .verificationFailed(let offset):
            return FailureExplanation(
                title: "Verification failed",
                message: "The data read back from the drive does not match the image, first \(position(offset)). The drive may be faulty, or smaller than it claims.",
                drive: .doesNotMatch
            )
        case .deviceEnded(let offset):
            return FailureExplanation(
                title: "The drive is smaller than it claims",
                message: "The drive stopped returning data \(position(offset)), inside the size it reports. It may be faulty or counterfeit.",
                drive: .doesNotMatch
            )
        case .read(let ioError):
            return deviceError(ioError, during: "verification", otherwise: "Reading the drive back failed.", drive: .unverified)
        case .imageTooLarge:
            return FailureExplanation(
                title: "The drive couldn’t be verified",
                message: "The drive reported a size too small to hold the image, so it could not be checked.",
                drive: .unverified,
                details: error.localizedDescription
            )
        }
    }

    // MARK: - Shared

    /// ENXIO and ENODEV come back once a drive is unplugged; EIO can mean the same or a
    /// failing drive. Either way the run stops: it is never retried, on this or any disk.
    private static func deviceError(
        _ error: DeviceIOError,
        during activity: String,
        otherwise: String,
        drive: DriveCondition
    ) -> FailureExplanation {
        if case .posix(_, let code) = error {
            switch code {
            case ENXIO, ENODEV:
                return FailureExplanation(
                    title: "The drive was disconnected",
                    message: "The drive stopped responding during \(activity), probably because it was removed. Writing stopped and was not retried.",
                    drive: drive,
                    details: error.localizedDescription
                )
            case EIO:
                return FailureExplanation(
                    title: "The drive stopped responding",
                    message: "The drive reported an error during \(activity). It may have been removed, or it may be faulty. Writing stopped and was not retried.",
                    drive: drive,
                    details: error.localizedDescription
                )
            default:
                break
            }
        }
        return FailureExplanation(
            title: "The drive reported an error",
            message: otherwise,
            drive: drive,
            details: error.localizedDescription
        )
    }

    private static func explain(_ error: ImageSourceError, stage: PipelineStage) -> FailureExplanation {
        let message: String
        switch error {
        case .changed(let name):
            message = "“\(name)” changed after it was selected. Choose the image again."
        case .truncated(let name, _):
            message = "“\(name)” became shorter while it was being read. Check the file and choose it again."
        case .posix(_, let name, _):
            message = "“\(name)” could not be read. Check that the file is still there and readable."
        }
        return FailureExplanation(
            title: "The image file couldn’t be read",
            message: message,
            drive: stage == .verify ? .unverified : .partiallyWritten,
            details: error.localizedDescription
        )
    }

    /// The device failing outside a read or write, e.g. its geometry after the open.
    private static func explain(_ error: DeviceIOError, stage: PipelineStage) -> FailureExplanation {
        FailureExplanation(
            title: "The drive reported an error",
            message: "The drive could not be used while \(stage.label.lowercased()).",
            drive: DriveCondition(stoppedIn: stage),
            details: error.localizedDescription
        )
    }

    /// diskutil (safety check, unmount) could not be run or did not answer.
    private static func explain(_ error: CommandRunnerError, stage: PipelineStage) -> FailureExplanation {
        FailureExplanation(
            title: "A system tool didn’t respond",
            message: "macOS did not respond while \(stage.label.lowercased()). Try again, and restart the Mac if it keeps happening.",
            drive: DriveCondition(stoppedIn: stage),
            details: error.localizedDescription
        )
    }

    private static func fallback(_ error: any Error, stage: PipelineStage) -> FailureExplanation {
        FailureExplanation(
            title: "The write failed",
            message: "Something went wrong while \(stage.label.lowercased()).",
            drive: DriveCondition(stoppedIn: stage),
            details: error.localizedDescription
        )
    }

    /// "at byte 8388608 (8.4 MB in)": the size makes a large offset readable.
    private static func position(_ offset: UInt64) -> String {
        offset < 1000 ? "at byte \(offset)" : "at byte \(offset) (\(DisplayFormat.size(offset)) in)"
    }
}
