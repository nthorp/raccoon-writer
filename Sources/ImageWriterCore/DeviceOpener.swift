import Foundation

/// The privilege seam, in two steps so the password prompt can come before the last
/// safety check: `authorize` asks for permission, and the grant it returns opens the
/// disk without asking again. `AuthopenOpener` is the production implementation; an
/// SMAppService helper could replace it.
public protocol DeviceOpener: Sendable {
    /// Shows the admin prompt for `/dev/r<bsdName>` and returns permission to open it.
    /// Opens nothing. `bsdName` must match `^disk[0-9]+$`.
    func authorize(bsdName: String) async throws -> any DeviceGrant
}
