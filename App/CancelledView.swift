import SwiftUI
import ImageWriterCore

struct CancelledView: View {
    let stage: PipelineStage
    let onStartAgain: () -> Void

    var body: some View {
        OutcomeView(
            systemImage: "stop.circle.fill",
            tint: .secondary,
            title: "Cancelled",
            buttonTitle: "Start Again",
            action: onStartAgain
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stopped while: \(stage.label.lowercased()).")
                    .foregroundStyle(.secondary)
                Label(stage.driveStateNote, systemImage: "externaldrive")
            }
        }
    }
}

#if DEBUG
#Preview("Cancelled before writing") {
    CancelledView(stage: .open, onStartAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Cancelled during write") {
    CancelledView(stage: .write, onStartAgain: {})
        .padding(24)
        .frame(width: 580, height: 500)
}
#endif
