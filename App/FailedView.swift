import SwiftUI
import ImageWriterCore

struct FailedView: View {
    let failure: WriteFailure
    let onTryAgain: () -> Void

    var body: some View {
        OutcomeView(
            systemImage: "xmark.octagon.fill",
            tint: .red,
            title: "The write failed",
            buttonTitle: "Try Again",
            action: onTryAgain
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(failure.message)
                Text("Failed while: \(failure.stage.label.lowercased()).")
                    .foregroundStyle(.secondary)
                Label(failure.stage.driveStateNote, systemImage: "externaldrive")
            }
        }
    }
}

#if DEBUG
#Preview("Failed during write") {
    FailedView(failure: PreviewSamples.writeFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Failed safety check") {
    FailedView(failure: PreviewSamples.safetyFailure, onTryAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}
#endif
