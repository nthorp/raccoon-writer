import Foundation

/// Obtains the authorization authopen needs to open a disk, so the password dialog
/// names ISO Sword rather than authopen (`authopen -extauth`).
/// `SecurityAuthorizer` is the production implementation.
public protocol DeviceAuthorizer: Sendable {
    /// Authorizes `sys.openfile.readwrite.<devicePath>`. Blocks while the dialog is up,
    /// so call it off the cooperative pool. Throws `DeviceOpenError`.
    func authorize(devicePath: String) throws -> any DeviceAuthorization
}
