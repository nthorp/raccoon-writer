import Foundation

/// Permission to open one disk, from `DeviceOpener.authorize`. It covers the device
/// path, not the medium behind it: if the drive is swapped, another disk can take the
/// same name. Check the disk again just before `open()`.
public protocol DeviceGrant: AnyObject, Sendable {
    var bsdName: String { get }

    /// Opens `/dev/r<bsdName>` read-write without prompting. Not after `release()`.
    func open() async throws -> any OpenedDevice

    /// Gives up the permission, so the next write prompts again. Call it once the disk
    /// is open or the run has ended; later calls do nothing.
    func release()
}
