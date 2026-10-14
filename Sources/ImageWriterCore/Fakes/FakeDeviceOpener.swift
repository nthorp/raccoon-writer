#if DEBUG
import Foundation

/// A `DeviceOpener` that grants every authorization (or throws a prepared error) and
/// opens prepared devices (usually `FileBackedDevice`), for tests and the debug
/// "Simulate" mode.
public final class FakeDeviceOpener: DeviceOpener, @unchecked Sendable {
    public typealias Authorizer = @Sendable (String) throws -> Void
    public typealias Factory = @Sendable (String) throws -> any OpenedDevice

    private let lock = NSLock()
    private let authorizer: Authorizer
    private let factory: Factory
    private var authorizations: [String] = []
    private var opens: [String] = []
    private var issued: [FakeDeviceGrant] = []

    /// `authorize` stands in for the dialog: throw to refuse or cancel it.
    /// `factory` stands in for the open that follows.
    public init(authorize: @escaping Authorizer = { _ in }, factory: @escaping Factory) {
        self.authorizer = authorize
        self.factory = factory
    }

    public convenience init(device: any OpenedDevice) {
        self.init { _ in device }
    }

    /// The dialog fails with `error` (`.userCancelled` for a dismissed dialog).
    public convenience init(authorizeError error: DeviceOpenError) {
        self.init(authorize: { _ in throw error }, factory: { _ in throw error })
    }

    /// The dialog succeeds and the open fails with `error`.
    public convenience init(openError error: DeviceOpenError) {
        self.init { _ in throw error }
    }

    /// BSD names of every authorization that passed name validation, in order.
    public var authorizeAttempts: [String] { lock.withLock { authorizations } }

    /// BSD names of every open, in order.
    public var openAttempts: [String] { lock.withLock { opens } }

    /// Every grant handed out, in order.
    public var grants: [FakeDeviceGrant] { lock.withLock { issued } }

    public func authorize(bsdName: String) async throws -> any DeviceGrant {
        // Same name rule as production, so callers can't rely on the fake being lax.
        guard BSDName.isWholeDisk(bsdName) else { throw DeviceOpenError.invalidDiskName(bsdName) }
        lock.withLock { authorizations.append(bsdName) }
        try authorizer(bsdName)
        let grant = FakeDeviceGrant(bsdName: bsdName, opener: self)
        lock.withLock { issued.append(grant) }
        return grant
    }

    fileprivate func open(_ bsdName: String) throws -> any OpenedDevice {
        lock.withLock { opens.append(bsdName) }
        return try factory(bsdName)
    }
}

/// Counts its releases so tests can check the permission is given up exactly once.
public final class FakeDeviceGrant: DeviceGrant, @unchecked Sendable {
    public let bsdName: String
    private let opener: FakeDeviceOpener
    private let lock = NSLock()
    private var releases = 0

    fileprivate init(bsdName: String, opener: FakeDeviceOpener) {
        self.bsdName = bsdName
        self.opener = opener
    }

    public var releaseCount: Int { lock.withLock { releases } }

    /// Refuses after `release()`, as authopen would with destroyed rights.
    public func open() async throws -> any OpenedDevice {
        guard releaseCount == 0 else { throw DeviceOpenError.permissionDenied }
        return try opener.open(bsdName)
    }

    public func release() {
        lock.withLock { releases += 1 }
    }
}
#endif
