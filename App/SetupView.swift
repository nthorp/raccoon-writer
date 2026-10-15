import SwiftUI
import ImageWriterCore

/// The image and drive steps on one screen: pick an image, then a drive, then continue
/// to the confirmation.
struct SetupView: View {
    let image: ImageInfo?
    let imageError: String?
    let selectedDrive: DiskInfo?
    /// Set when the selected image can't fit on the selected drive.
    let driveTooSmall: DriveTooSmall?
    /// Set when the selected image is stored on the selected drive.
    let imageOnDrive: ImageOnDrive?
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
                image: image,
                selected: selectedDrive,
                isEnabled: image != nil,
                hasLoaded: hasLoadedDrives,
                errorMessage: driveListError,
                showAllExternal: $showAllExternal,
                onSelect: onSelectDrive,
                onRefresh: onRefreshDrives
            )

            HStack {
                // One message at a time; the image being on the drive is the more basic problem.
                if let message = imageOnDrive?.message ?? driveTooSmall?.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Continue…", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil || selectedDrive == nil || driveTooSmall != nil || imageOnDrive != nil)
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
        image: nil, imageError: nil, selectedDrive: nil, driveTooSmall: nil, imageOnDrive: nil,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Image selected, with warning") {
    SetupView(
        image: PreviewSamples.isoOnlyImage, imageError: nil, selectedDrive: nil, driveTooSmall: nil, imageOnDrive: nil,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Drive selected") {
    SetupView(
        image: PreviewSamples.image, imageError: nil, selectedDrive: PreviewSamples.stick, driveTooSmall: nil, imageOnDrive: nil,
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(true),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Drive too small") {
    SetupView(
        image: PreviewSamples.image, imageError: nil, selectedDrive: PreviewSamples.tinyStick,
        driveTooSmall: DriveTooSmall(image: PreviewSamples.image, drive: PreviewSamples.tinyStick), imageOnDrive: nil,
        drives: PreviewSamples.drives + [PreviewSamples.tinyStick], hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(true),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Image on the drive") {
    SetupView(
        image: PreviewSamples.imageOnStick, imageError: nil, selectedDrive: PreviewSamples.stick,
        driveTooSmall: nil, imageOnDrive: ImageOnDrive(image: PreviewSamples.imageOnStick, drive: PreviewSamples.stick),
        drives: PreviewSamples.drives, hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}

#Preview("Rejected file, no drives") {
    SetupView(
        image: nil, imageError: "“notes.txt” is not an .iso or .img file.", selectedDrive: nil, driveTooSmall: nil, imageOnDrive: nil,
        drives: [], hasLoadedDrives: true, driveListError: nil,
        showAllExternal: .constant(false),
        onChooseImage: {}, onSelectDrive: { _ in }, onRefreshDrives: {}, onContinue: {}
    )
    .padding(24)
    .frame(width: 580, height: 500)
}
#endif
