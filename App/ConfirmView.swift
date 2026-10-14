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
            // Above the title: coming back here otherwise looks like nothing happened.
            if let notice {
                NoticeCallout(message: notice.message)
            }

            Label("Erase this drive?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)

            // Built from pieces rather than Markdown, so a drive name is never parsed.
            (Text("You are about to erase ")
                + Text(disk.mediaName.isEmpty ? "Unnamed drive" : disk.mediaName).bold()
                + Text(" (\(DisplayFormat.size(disk.sizeBytes)), \(disk.devicePath)).")
            )
            .fixedSize(horizontal: false, vertical: true)

            if let largeDrive = LargeDriveWarning(drive: disk) {
                Label(largeDrive.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

/// A tinted box so the notice isn't read as a secondary hint. The text keeps the
/// primary colour for contrast in both appearances; only the icon carries the tint.
private struct NoticeCallout: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.blue.opacity(0.3)))
    }
}

#if DEBUG
#Preview("Awaiting confirmation") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.stick, notice: nil, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Large drive") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.usbHardDrive, notice: nil, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 580, height: 500)
}

#Preview("Large drive, back after the password dialog was cancelled") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.usbHardDrive, notice: .passwordPromptCancelled, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 540, height: 500)
}

#Preview("Back after the password dialog was cancelled") {
    ConfirmView(image: PreviewSamples.image, disk: PreviewSamples.stick, notice: .passwordPromptCancelled, onCancel: {}, onConfirm: {})
        .padding(24)
        .frame(width: 580, height: 500)
}
#endif
