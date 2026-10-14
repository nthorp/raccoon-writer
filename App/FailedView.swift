import AppKit
import SwiftUI
import ImageWriterCore

/// The wording comes from `FailureExplanation`, so every error's text is unit-tested.
struct FailedView: View {
    let explanation: FailureExplanation
    let stage: PipelineStage
    let onTryAgain: () -> Void

    init(failure: WriteFailure, onTryAgain: @escaping () -> Void) {
        explanation = FailureExplanation(failure)
        stage = failure.stage
        self.onTryAgain = onTryAgain
    }

    var body: some View {
        OutcomeView(
            systemImage: "xmark.octagon.fill",
            tint: .red,
            title: explanation.title,
            buttonTitle: "Try Again",
            action: onTryAgain,
            secondary: secondaryButton
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if explanation.remedies.isEmpty {
                    Text(explanation.message)
                } else {
                    NoticeCallout(message: explanation.message)
                    ForEach(Array(explanation.remedies.enumerated()), id: \.offset) { index, remedy in
                        RemedyView(letter: RemedyView.letter(for: index), remedy: remedy)
                    }
                }
                Label(explanation.drive.note, systemImage: "externaldrive")
                Text("Stopped while: \(stage.label.lowercased()).")
                    .foregroundStyle(.secondary)
                if let details = explanation.details {
                    Text("Details: \(details)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var secondaryButton: OutcomeButton? {
        switch explanation.action {
        case .openFullDiskAccessSettings:
            guard let url = PrivacySettingsLink.fullDiskAccess else { return nil }
            return OutcomeButton(title: "Open Full Disk Access Settings…") { NSWorkspace.shared.open(url) }
        case nil:
            return nil
        }
    }
}

#if DEBUG
#Preview("Failed: drive removed") {
    FailedView(failure: PreviewSamples.writeFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Failed: verification") {
    FailedView(failure: PreviewSamples.verifyFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Failed: privacy settings") {
    FailedView(failure: PreviewSamples.privacyFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Failed safety check") {
    FailedView(failure: PreviewSamples.safetyFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}
#endif
