import Foundation

/// Permission from `AuthopenOpener.authorize`: the authorization for one raw device
/// path, handed to authopen with `-extauth` at `open()`, so authopen doesn't prompt.
final class AuthopenGrant: DeviceGrant, @unchecked Sendable {
    let bsdName: String
    let devicePath: String
    let executable: String
    private let authorization: any DeviceAuthorization
    private let lock = NSLock()
    private var released = false

    init(bsdName: String, executable: String, authorization: any DeviceAuthorization) {
        self.bsdName = bsdName
        self.devicePath = "/dev/r\(bsdName)"
        self.executable = executable
        self.authorization = authorization
    }

    /// Blocks a background thread, not the caller, while authopen runs. authopen resolves
    /// the external form as it runs, so the caller releases only after this returns.
    func open() async throws -> any OpenedDevice {
        let executable = executable
        let authorization = authorization
        let devicePath = devicePath
        let fd = try await AuthopenOpener.offCooperativePool {
            try AuthopenOpener.obtainDescriptor(executable: executable, authorization: authorization, devicePath: devicePath)
        }
        do {
            return try RawDevice(fd: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func release() {
        let first = lock.withLock {
            defer { released = true }
            return !released
        }
        if first {
            authorization.release()
        }
    }

    deinit {
        release()
    }
}
