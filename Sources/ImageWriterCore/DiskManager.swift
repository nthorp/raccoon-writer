import Foundation

/// Releases a disk before the write and ejects it afterwards. `DiskutilDiskManager` is
/// the production implementation; tests use `FakeDiskManager`.
public protocol DiskManager: Sendable {
    /// Unmounts every volume on the whole disk. A disk with nothing mounted succeeds.
    /// `bsdName` must match `^disk[0-9]+$`.
    func unmountWholeDisk(bsdName: String) async throws

    /// Mounts the volumes on the whole disk, undoing `unmountWholeDisk` for a run that
    /// stopped before writing. `bsdName` must match `^disk[0-9]+$`.
    func mountWholeDisk(bsdName: String) async throws

    /// Unmounts and ejects the whole disk. `bsdName` must match `^disk[0-9]+$`.
    func eject(bsdName: String) async throws
}

extension DiskManager {
    /// Ejects after a successful write and verify. A failure here doesn't undo the write,
    /// so it comes back as a warning for the summary instead of being thrown.
    public func ejectAfterWrite(bsdName: String) async -> EjectWarning? {
        do {
            try await eject(bsdName: bsdName)
            return nil
        } catch {
            return EjectWarning(bsdName: bsdName, reason: error.localizedDescription)
        }
    }
}
