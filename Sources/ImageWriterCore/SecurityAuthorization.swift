import Foundation
import Security

/// Owns an `AuthorizationRef` from `SecurityAuthorizer`. Created on the thread that
/// showed the dialog and released from another, so `reference` is guarded by `lock`.
final class SecurityAuthorization: DeviceAuthorization, @unchecked Sendable {
    let externalForm: [UInt8]
    private let lock = NSLock()
    private var reference: AuthorizationRef?

    init(reference: AuthorizationRef, externalForm: [UInt8]) {
        self.reference = reference
        self.externalForm = externalForm
    }

    /// `destroyRights` removes the cached credential: an in-process authorization would
    /// otherwise be reused for the right's 300 s timeout, and every write must prompt.
    func release() {
        let reference = lock.withLock {
            let current = self.reference
            self.reference = nil
            return current
        }
        guard let reference else { return }
        AuthorizationFree(reference, [.destroyRights])
    }

    deinit {
        release()
    }
}
