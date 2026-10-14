#if DEBUG
import Foundation

/// Debug builds only. With `RACCOONWRITER_SIMULATE=1` the app runs the whole flow against
/// fakes: a fixed list of `SimulatedDrive`s, no diskutil, no authopen, and temp files
/// in place of devices. The whole type is compiled out of Release builds, and
/// `scripts/check-release-flags.sh` fails a Release build that still contains it.
public enum SimulationMode {
    public static let environmentKey = "RACCOONWRITER_SIMULATE"

    /// True only when the variable is exactly `1`.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    /// The disks every simulated query sees, the boot disk included.
    public static var disks: [DiskInfo] { SimulatedDrive.allCases.map(\.disk) }

    static var bootResolver: StaticBootDiskResolver {
        StaticBootDiskResolver(wholeDisks: [SimulatedDrive.internalDisk.bsdName])
    }

    public static func makeLister() -> TargetDiskLister {
        TargetDiskLister(discovery: StaticDiskDiscovery(disks: disks), bootResolver: bootResolver)
    }

    /// `promptDelay` stands in for the time spent in the admin password dialog.
    @MainActor
    public static func makeCoordinator(
        promptDelay: Duration = .seconds(2),
        directory: URL = FileManager.default.temporaryDirectory
    ) -> WriteCoordinator {
        let opener = FakeDeviceOpener(authorize: { bsdName in
            if SimulatedDrive(bsdName: bsdName) == .promptCancelled { throw DeviceOpenError.userCancelled }
        }) { bsdName in
            guard let drive = SimulatedDrive(bsdName: bsdName) else {
                throw DeviceOpenError.authopenFailed(status: 1, message: "Simulate: no simulated drive \(bsdName)")
            }
            if drive == .privacyBlocked { throw DeviceOpenError.blockedByPrivacySettings }
            return try drive.openDevice(in: directory)
        }
        return WriteCoordinator(
            safetyGuard: SafetyGuard(discovery: StaticDiskDiscovery(disks: disks), bootResolver: bootResolver),
            diskManager: FakeDiskManager(),
            opener: SimulatedOpener(promptDelay: promptDelay, inner: opener)
        )
    }
}
#endif
