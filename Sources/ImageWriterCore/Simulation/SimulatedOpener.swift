#if DEBUG
import Foundation

/// Debug Simulate mode only. Waits as if the admin password dialog were up, then
/// authorizes through a `FakeDeviceOpener`. Unlike the real dialog, a cancel during
/// the wait is honored.
struct SimulatedOpener: DeviceOpener {
    let promptDelay: Duration
    let inner: FakeDeviceOpener

    func authorize(bsdName: String) async throws -> any DeviceGrant {
        try await Task.sleep(for: promptDelay)
        return try await inner.authorize(bsdName: bsdName)
    }
}
#endif
