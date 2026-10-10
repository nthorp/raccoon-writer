import SwiftUI
import ImageWriterCore

/// Preparing, writing, verifying and finishing. The wording comes from `ProgressDisplay`.
struct ProgressStepView: View {
    let state: WriteState
    let isCancelling: Bool
    let imageName: String?
    let driveName: String?
    let onCancel: () -> Void

    var body: some View {
        if let display = ProgressDisplay(state: state, isCancelling: isCancelling) {
            VStack(alignment: .leading, spacing: 14) {
                if let imageName, let driveName {
                    Text("\(imageName) → \(driveName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(display.title)
                    .font(.title2.bold())

                if let fraction = display.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(alignment: .firstTextBaseline) {
                    if let percent = display.percentText {
                        Text(percent).font(.title3.monospacedDigit())
                    }
                    if let bytes = display.bytesText {
                        Text(bytes).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                }

                if display.speedText != nil || display.remainingText != nil {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        if let speed = display.speedText {
                            GridRow {
                                Text("Speed:").foregroundStyle(.secondary)
                                Text(speed).monospacedDigit()
                            }
                        }
                        if let remaining = display.remainingText {
                            GridRow {
                                Text("Time left:").foregroundStyle(.secondary)
                                Text(remaining).monospacedDigit()
                            }
                        }
                    }
                }

                if let detail = display.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack {
                    Spacer()
                    Button(display.cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!display.canCancel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
private func progressPreview(_ state: WriteState, isCancelling: Bool = false) -> some View {
    ProgressStepView(
        state: state, isCancelling: isCancelling,
        imageName: PreviewSamples.image.fileName, driveName: PreviewSamples.stick.mediaName,
        onCancel: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Safety check") { progressPreview(.preparing(.safetyCheck)) }
#Preview("Unmounting") { progressPreview(.preparing(.unmount)) }
#Preview("Password prompt") { progressPreview(.preparing(.open)) }
#Preview("Writing, speed unknown") { progressPreview(.writing(PreviewSamples.progress(0.01, speed: nil))) }
#Preview("Writing") { progressPreview(.writing(PreviewSamples.progress(0.42))) }
#Preview("Flushing") { progressPreview(.writing(PreviewSamples.progress(1))) }
#Preview("Verifying") { progressPreview(.verifying(PreviewSamples.progress(0.7))) }
#Preview("Cancelling") { progressPreview(.verifying(PreviewSamples.progress(0.7)), isCancelling: true) }
#Preview("Ejecting") { progressPreview(.finishing) }
#endif
