import Foundation

/// A `DeviceOpener` that hands out prepared devices (usually `FileBackedDevice`)
/// or throws a prepared error, for tests and the debug "Simulate" mode.
public final class FakeDeviceOpener: DeviceOpener, @unchecked Sendable {
    public typealias Factory = @Sendable (String) throws -> any OpenedDevice

    private let lock = NSLock()
    private let factory: Factory
    private var attempts: [String] = []

    public init(factory: @escaping Factory) {
        self.factory = factory
    }

    public convenience init(device: any OpenedDevice) {
        self.init { _ in device }
    }

    public convenience init(error: DeviceOpenError) {
        self.init { _ in throw error }
    }

    /// BSD names of every open that passed name validation, in order.
    public var openAttempts: [String] { lock.withLock { attempts } }

    public func openForReadWrite(bsdName: String) async throws -> any OpenedDevice {
        // Same name rule as production, so callers can't rely on the fake being lax.
        guard BSDName.isWholeDisk(bsdName) else { throw DeviceOpenError.invalidDiskName(bsdName) }
        lock.withLock { attempts.append(bsdName) }
        return try factory(bsdName)
    }
}
