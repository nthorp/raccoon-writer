import SwiftUI
import ImageWriterCore

/// The drive list with its "Show all external disks" toggle and the empty, loading and
/// error states. Disabled until an image is chosen.
struct DriveSection: View {
    let drives: [DiskInfo]
    /// The chosen image, so drives too small for it can be marked.
    let image: ImageInfo?
    let selected: DiskInfo?
    let isEnabled: Bool
    let hasLoaded: Bool
    let errorMessage: String?
    @Binding var showAllExternal: Bool
    let onSelect: (DiskInfo) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            list
                .frame(minHeight: 140)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.6)
            HStack {
                Toggle("Show all external disks", isOn: $showAllExternal)
                Spacer()
                if !isEnabled {
                    Text("Select an image first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for drives again")
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let errorMessage {
            placeholder(
                "Couldn’t list drives",
                systemImage: "exclamationmark.triangle",
                detail: "\(errorMessage) No drives are shown until the disks can be checked."
            )
        } else if !hasLoaded {
            placeholder("Looking for drives…", systemImage: "magnifyingglass", detail: nil)
        } else if drives.isEmpty {
            placeholder(
                "Insert a USB drive",
                systemImage: "externaldrive.badge.plus",
                detail: showAllExternal
                    ? "No external disks found."
                    : "Only USB drives are listed. Turn on “Show all external disks” for other external disks."
            )
        } else {
            List(drives, selection: selection) { disk in
                DriveRow(
                    disk: disk,
                    isTooSmall: image.flatMap { DriveTooSmall(image: $0, drive: disk) } != nil,
                    isLarge: LargeDriveWarning(drive: disk) != nil
                )
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selected?.bsdName },
            set: { name in
                guard let disk = drives.first(where: { $0.bsdName == name }) else { return }
                onSelect(disk)
            }
        )
    }

    private func placeholder(_ title: String, systemImage: String, detail: String?) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let detail { Text(detail) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DriveRow: View {
    let disk: DiskInfo
    let isTooSmall: Bool
    let isLarge: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.mediaName.isEmpty ? "Unnamed drive" : disk.mediaName)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isTooSmall {
                    Text("Too small for this image")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if isLarge {
                    Text("Large drive")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [DisplayFormat.size(disk.sizeBytes), disk.devicePath]
        if let bus = disk.busProtocol { parts.append(bus) }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Loading") {
    DriveSection(
        drives: [], image: nil, selected: nil, isEnabled: true, hasLoaded: false, errorMessage: nil,
        showAllExternal: .constant(false), onSelect: { _ in }, onRefresh: {}
    )
    .padding()
    .frame(width: 540, height: 240)
}

#Preview("Drives, one large") {
    DriveSection(
        drives: PreviewSamples.drives + [PreviewSamples.usbHardDrive], image: PreviewSamples.image,
        selected: PreviewSamples.usbHardDrive, isEnabled: true, hasLoaded: true, errorMessage: nil,
        showAllExternal: .constant(true), onSelect: { _ in }, onRefresh: {}
    )
    .padding()
    .frame(width: 540, height: 300)
}

#Preview("Error") {
    DriveSection(
        drives: [], image: nil, selected: nil, isEnabled: true, hasLoaded: true,
        errorMessage: "The boot disk could not be identified.",
        showAllExternal: .constant(false), onSelect: { _ in }, onRefresh: {}
    )
    .padding()
    .frame(width: 540, height: 240)
}
#endif
