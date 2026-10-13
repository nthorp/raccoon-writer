import Foundation

/// A granted authorization, kept alive until authopen has exited because authopen
/// resolves the external form while it runs. The owner must call `release()` once.
public protocol DeviceAuthorization: AnyObject, Sendable {
    /// `AuthorizationExternalForm`: exactly `kAuthorizationExternalFormLength` (32) bytes,
    /// written to authopen's stdin.
    var externalForm: [UInt8] { get }

    /// Frees the authorization and destroys its rights, so the next write prompts again.
    /// Calling it more than once has no further effect.
    func release()
}
