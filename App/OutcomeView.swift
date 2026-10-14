import SwiftUI

/// The shared layout of the done, failed and cancelled screens.
struct OutcomeView<Details: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let buttonTitle: String
    let action: () -> Void
    var secondary: OutcomeButton? = nil
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title).font(.title2.bold())
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.title2)

            details()
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                if let secondary {
                    Button(secondary.title, action: secondary.action)
                }
                Button(buttonTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
