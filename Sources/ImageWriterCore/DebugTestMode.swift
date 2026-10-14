#if DEBUG
import Foundation

/// Debug builds only. Lets the drive list offer unmounted disk images (an
/// `hdiutil attach -nomount ram://…` RAM disk) so the app can be tried without a spare
/// USB stick. The whole type is compiled out of Release builds, and
/// `scripts/check-release-flags.sh` fails a Release build that still contains it.
public enum DebugTestMode {
    public static let environmentKey = "RACCOONWRITER_ALLOW_VIRTUAL_DISKS"

    /// True only when the variable is exactly `1`.
    public static func allowsVirtualDisks(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}
#endif
