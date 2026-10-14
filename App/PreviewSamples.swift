#if DEBUG
import Foundation
import ImageWriterCore

/// Sample values for the SwiftUI previews of each step.
enum PreviewSamples {
    static let image = ImageInfo(
        url: URL(fileURLWithPath: "/Users/me/Downloads/Fedora-Workstation-Live-x86_64-40-1.14.iso"),
        fileName: "Fedora-Workstation-Live-x86_64-40-1.14.iso",
        sizeBytes: 2_295_853_056, identity: madeUpIdentity(sizeBytes: 2_295_853_056), kind: .iso,
        hasMBR: true, hasGPT: true, isISO9660: true, bootWarning: nil
    )

    static let isoOnlyImage = ImageInfo(
        url: URL(fileURLWithPath: "/Users/me/Downloads/old-installer.iso"),
        fileName: "old-installer.iso",
        sizeBytes: 700_000_000, identity: madeUpIdentity(sizeBytes: 700_000_000), kind: .iso,
        hasMBR: false, hasGPT: false, isISO9660: true, bootWarning: .mayNotBootFromUSB
    )

    /// Previews never open the image, so its identity is never checked.
    private static func madeUpIdentity(sizeBytes: Int64) -> FileIdentity {
        FileIdentity(device: 1, inode: 1, sizeBytes: sizeBytes, modifiedSeconds: 0, modifiedNanoseconds: 0)
    }

    static let stick = DiskInfo(
        bsdName: "disk4", mediaName: "SanDisk Ultra", sizeBytes: 30_752_636_928, blockSize: 512,
        busProtocol: "USB", isInternal: false, isRemovable: true, isEjectable: true,
        isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/STICK"], volumeNames: ["STICK"]
    )

    static let ssd = DiskInfo(
        bsdName: "disk5", mediaName: "Samsung T7", sizeBytes: 500_107_862_016, blockSize: 512,
        busProtocol: "PCI-Express", isInternal: false, isRemovable: false, isEjectable: true,
        isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/Backup"], volumeNames: ["Backup"]
    )

    /// Over the `LargeDriveWarning` threshold; ejectable-only, as USB hard drives report.
    static let usbHardDrive = DiskInfo(
        bsdName: "disk7", mediaName: "WD Elements", sizeBytes: 2_000_398_934_016, blockSize: 512,
        busProtocol: "USB", isInternal: false, isRemovable: false, isEjectable: true,
        isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/Time Machine"], volumeNames: ["Time Machine"]
    )

    static let tinyStick = DiskInfo(
        bsdName: "disk6", mediaName: "Kingston DataTraveler", sizeBytes: 2_000_683_008, blockSize: 512,
        busProtocol: "USB", isInternal: false, isRemovable: true, isEjectable: true,
        isVirtual: false, isWholeDisk: true, mountPoints: ["/Volumes/OLD"], volumeNames: ["OLD"]
    )

    static let drives = [stick, ssd]

    static func progress(_ fraction: Double, speed: Double? = 31_400_000) -> TransferProgress {
        TransferProgress(
            completedBytes: UInt64(Double(image.sizeBytes) * fraction),
            totalBytes: image.sizeBytes,
            bytesPerSecond: speed
        )
    }

    static func summary(ejectWarning: EjectWarning?) -> WriteSummary {
        WriteSummary(
            imageName: image.fileName, driveName: stick.mediaName, bsdName: stick.bsdName,
            bytes: image.sizeBytes, writeSeconds: 74, verifySeconds: 31, totalSeconds: 112,
            syncMethod: .synchronize, ejectWarning: ejectWarning
        )
    }

    static let writeFailure = WriteFailure(
        stage: .write,
        error: WriteEngineError.write(.posix(operation: "write at offset 104857600", code: ENXIO))
    )

    static let verifyFailure = WriteFailure(
        stage: .verify,
        error: VerifierError.verificationFailed(atOffset: 8_388_608)
    )

    static let safetyFailure = WriteFailure(
        stage: .safetyCheck,
        error: SafetyGuardError.diskMissing(bsdName: "disk4")
    )
}
#endif
