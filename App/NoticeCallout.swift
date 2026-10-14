import SwiftUI

/// A tinted box so the notice isn't read as a secondary hint (T18), also used to
/// introduce the fixes on the failed screen. The text keeps the primary colour for
/// contrast in both appearances; only the icon carries the tint.
struct NoticeCallout: View {
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
