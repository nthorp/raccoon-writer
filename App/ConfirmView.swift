import SwiftUI
import ImageWriterCore

/// The last stop before erasing. Nothing is the default button, so Return can't erase.
struct ConfirmView: View {
    let image: ImageInfo
    let disk: DiskInfo
    /// Why the run came back here, e.g. the password dialog was cancelled.
    let notice: WriteNotice?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Erase this drive?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)

            if let notice {
                Label(notice.message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Built from pieces rather than Markdown, so a drive name is never parsed.
            (Text("You are about to erase ")
                + Text(disk.mediaName.isEmpty ? "Unnamed drive" : disk.mediaName).bold()
                + Text(" (\(DisplayFormat.size(disk.sizeBytes)), \(disk.devicePath)).")
            )
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Mounted volumes:").foregroundStyle(.secondary)
                    Text(DisplayFormat.mountPoints(of: disk))
                }
                GridRow {
                    Text("Image:").foregroundStyle(.secondary)
                    Text("\(image.fileName) (\(DisplayFormat.size(image.sizeBytes)))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text("All data on this drive will be permanently lost.")
                .bold()

            Text("\(AppInfo.shortName) will ask for an administrator password.")

            Spacer()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Write", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Awaiting confirmation") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.stick, notice: nil, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Back after the password dialog was cancelled") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.stick, notice: .passwordPromptCancelled, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 580, height: 500)
}
#endif
