import SwiftUI
import ImageWriterCore

/// The image and drive steps on one screen: pick an image, then a drive, then continue
/// to the confirmation.
struct SetupView: View {
    let image: ImageInfo?
    let imageError: String?
    let selectedDrive: DiskInfo?
    let drives: [DiskInfo]
    let hasLoadedDrives: Bool
    let driveListError: String?
    @Binding var showAllExternal: Bool
    let onChooseImage: () -> Void
    let onSelectDrive: (DiskInfo) -> Void
    let onRefreshDrives: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(number: 1, title: "Image")
            ImageSection(image: image, errorMessage: imageError, onChoose: onChooseImage)

            StepHeader(number: 2, title: "Drive")
            DriveSection(
                drives: drives,
                selected: selectedDrive,
                isEnabled: image != nil,
                hasLoaded: hasLoadedDrives,
                errorMessage: driveListError,
                showAllExternal: $showAllExternal,
                onSelect: onSelectDrive,
                onRefresh: onRefreshDrives
            )

            HStack {
                Spacer()
                Button("Continue…", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil || selectedDrive == nil)
            }
        }
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}

#if DEBUG
#Preview("Idle") {
    SetupView(
        image: nil, imageError: nil, selectedDrive: nil,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Image selected, with warning") {
    SetupView(
        image: PreviewSamples.isoOnlyImage, imageError: nil, selectedDrive: nil,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Drive selected") {
    SetupView(
        image: PreviewSamples.image, imageError: nil, selectedDrive: PreviewSamples.stick,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(true),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Rejected file, no drives") {
    SetupView(
        image: nil, imageError: "“notes.txt” is not an .iso or .img file.", selectedDrive: nil,
        drives: [], hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}
#endif
