#if DEBUG
import Foundation

/// Debug Simulate mode only. Waits as if the admin password dialog were up, then opens
/// through a `FakeDeviceOpener`. Unlike authopen, a cancel during the wait is honored.
struct SimulatedOpener: DeviceOpener {
    let promptDelay: Duration
    let inner: FakeDeviceOpener

    func openForReadWrite(bsdName: String) async throws -> any OpenedDevice {
        try await Task.sleep(for: promptDelay)
        return try await inner.openForReadWrite(bsdName: bsdName)
    }
}
#endif
