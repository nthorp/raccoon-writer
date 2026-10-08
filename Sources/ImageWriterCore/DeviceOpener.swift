import Foundation

/// The privilege seam: turns a whole-disk BSD name into a read-write handle.
/// `AuthopenOpener` is the production implementation; an SMAppService helper could replace it.
public protocol DeviceOpener: Sendable {
    /// Opens `/dev/r<bsdName>` read-write. `bsdName` must match `^disk[0-9]+$`.
    func openForReadWrite(bsdName: String) async throws -> any OpenedDevice
}
