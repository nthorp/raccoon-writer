import SwiftUI
import ImageWriterCore

/// One way to fix a failure, as `FailedView` lists them.
struct RemedyView: View {
    let remedy: FailureRemedy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(remedy.title).bold()
            Text(remedy.instructions)
            if let command = remedy.command {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if let note = remedy.note {
                Text(note).foregroundStyle(.secondary)
            }
        }
    }
}
