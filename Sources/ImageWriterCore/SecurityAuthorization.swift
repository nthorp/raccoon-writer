import Foundation
import Security

/// Owns an `AuthorizationRef` from `SecurityAuthorizer`.
final class SecurityAuthorization: DeviceAuthorization {
    let externalForm: [UInt8]
    private var reference: AuthorizationRef?

    init(reference: AuthorizationRef, externalForm: [UInt8]) {
        self.reference = reference
        self.externalForm = externalForm
    }

    /// `destroyRights` removes the cached credential: an in-process authorization would
    /// otherwise be reused for the right's 300 s timeout, and every write must prompt.
    func release() {
        guard let reference else { return }
        self.reference = nil
        AuthorizationFree(reference, [.destroyRights])
    }

    deinit {
        release()
    }
}
