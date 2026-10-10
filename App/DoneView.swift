import SwiftUI
import ImageWriterCore

struct DoneView: View {
    let summary: WriteSummary
    let onWriteAnother: () -> Void

    var body: some View {
        OutcomeView(
            systemImage: summary.ejectWarning == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            tint: summary.ejectWarning == nil ? .green : .orange,
            title: summary.ejectWarning == nil ? "Finished. You can remove the drive." : "Finished, but the drive is still attached",
            buttonTitle: "Write Another",
            action: onWriteAnother
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(summary.imageName) was written to \(summary.driveName) (\(summary.bsdName)) and verified.")
                if let warning = summary.ejectWarning {
                    Label(warning.message, systemImage: "eject")
                        .foregroundStyle(.orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Size:").foregroundStyle(.secondary)
                        Text(DisplayFormat.size(summary.bytes))
                    }
                    GridRow {
                        Text("Total time:").foregroundStyle(.secondary)
                        Text(DisplayFormat.duration(summary.totalSeconds))
                    }
                    GridRow {
                        Text("Average write speed:").foregroundStyle(.secondary)
                        Text(DisplayFormat.speed(summary.averageWriteBytesPerSecond))
                    }
                }
                .monospacedDigit()
            }
        }
    }
}

#if DEBUG
#Preview("Finished") {
    DoneView(summary: PreviewSamples.summary(ejectWarning: nil), onWriteAnother: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Finished, eject failed") {
    DoneView(
        summary: PreviewSamples.summary(ejectWarning: EjectWarning(bsdName: "disk4", reason: "Unmount was dissented")),
        onWriteAnother: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}
#endif
