import SwiftUI
import ImageWriterCore

/// One way to fix a failure, as `FailedView` lists them. The letter badge makes clear
/// that the fixes are alternatives, not steps to follow in order.
struct RemedyView: View {
    let letter: String
    let remedy: FailureRemedy

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(letter)
                .font(.callout.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())
                .accessibilityLabel("Option \(letter)")
            VStack(alignment: .leading, spacing: 6) {
                Text(remedy.title).font(.headline)
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

    /// "A", "B", … for the first few; a number after that, which no screen needs today.
    static func letter(for index: Int) -> String {
        let letters = Array("ABCDEFGH")
        return letters.indices.contains(index) ? String(letters[index]) : String(index + 1)
    }
}
