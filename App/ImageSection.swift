import SwiftUI
import ImageWriterCore

struct ImageSection: View {
    let image: ImageInfo?
    let errorMessage: String?
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "opticaldiscdrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                if let image {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(DisplayFormat.size(image.sizeBytes)) · .\(image.kind.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No image selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(image == nil ? "Select Image…" : "Change…", action: onChoose)
            }
            if let warning = image?.bootWarning {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
