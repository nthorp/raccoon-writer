import Foundation

/// What the progress screen shows for a running state. Kept out of the view so the
/// wording and the edge cases (flush after 100 %, unknown speed) are unit-tested.
public struct ProgressDisplay: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// Nil shows an indeterminate bar.
    public var fraction: Double?
    public var percentText: String?
    /// "1.2 GB of 4.7 GB".
    public var bytesText: String?
    public var speedText: String?
    public var remainingText: String?
    public var canCancel: Bool
    public var cancelTitle: String

    /// Nil for states that are not a run in progress.
    public init?(state: WriteState, isCancelling: Bool) {
        cancelTitle = isCancelling ? "Cancelling…" : "Cancel"
        canCancel = !isCancelling
        switch state {
        case .preparing(let stage):
            title = stage.label
            if stage == .authorize {
                detail = "Enter an administrator password in the dialog from \(AppInfo.shortName)."
            }
        case .writing(let progress) where progress.completedBytes >= progress.totalBytes:
            // The engine reports 100 % before the flush, which can take a while on USB.
            title = "Finishing the write"
            detail = "Flushing the last data to the drive…"
            fraction = 1
            percentText = DisplayFormat.percent(1)
            bytesText = Self.bytes(progress)
        case .writing(let progress):
            title = PipelineStage.write.label
            fill(progress)
        case .verifying(let progress):
            title = PipelineStage.verify.label
            detail = "Reading the drive back to check every byte."
            fill(progress)
        case .finishing:
            title = "Ejecting the drive"
            canCancel = false
        default:
            return nil
        }
    }

    private mutating func fill(_ progress: TransferProgress) {
        fraction = progress.fractionComplete
        percentText = DisplayFormat.percent(progress.fractionComplete)
        bytesText = Self.bytes(progress)
        speedText = DisplayFormat.speed(progress.bytesPerSecond)
        remainingText = DisplayFormat.remaining(progress.estimatedSecondsRemaining)
    }

    private static func bytes(_ progress: TransferProgress) -> String {
        "\(DisplayFormat.size(progress.completedBytes)) of \(DisplayFormat.size(progress.totalBytes))"
    }
}
