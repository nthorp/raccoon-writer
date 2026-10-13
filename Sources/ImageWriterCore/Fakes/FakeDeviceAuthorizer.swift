import Foundation

/// A `DeviceAuthorizer` that grants a fixed external form or throws a prepared error,
/// without showing a dialog. Tests use it to drive `AuthopenOpener` with a stand-in.
public final class FakeDeviceAuthorizer: DeviceAuthorizer, @unchecked Sendable {
    /// 32 distinct bytes, so a stand-in can check it received exactly these.
    public static let sampleExternalForm: [UInt8] = (0..<32).map { UInt8($0 * 7 + 3) }

    private let lock = NSLock()
    private let result: Result<[UInt8], DeviceOpenError>
    private var paths: [String] = []
    private var granted: [FakeDeviceAuthorization] = []

    public init(externalForm: [UInt8] = FakeDeviceAuthorizer.sampleExternalForm) {
        result = .success(externalForm)
    }

    public init(error: DeviceOpenError) {
        result = .failure(error)
    }

    /// Device paths of every authorization request, in order.
    public var requestedPaths: [String] { lock.withLock { paths } }

    /// Every authorization handed out, in order.
    public var authorizations: [FakeDeviceAuthorization] { lock.withLock { granted } }

    public func authorize(devicePath: String) throws -> any DeviceAuthorization {
        try lock.withLock {
            paths.append(devicePath)
            let authorization = FakeDeviceAuthorization(externalForm: try result.get())
            granted.append(authorization)
            return authorization
        }
    }
}

/// Counts its releases so tests can check the authorization is freed exactly once.
public final class FakeDeviceAuthorization: DeviceAuthorization, @unchecked Sendable {
    public let externalForm: [UInt8]
    private let lock = NSLock()
    private var releases = 0

    init(externalForm: [UInt8]) {
        self.externalForm = externalForm
    }

    public var releaseCount: Int { lock.withLock { releases } }

    public func release() {
        lock.withLock { releases += 1 }
    }
}
