#if DEBUG
import Foundation

/// A `DiskManager` that records calls and fails on request, for tests and the debug
/// "Simulate" mode. It never runs diskutil.
public final class FakeDiskManager: DiskManager, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case unmount(String)
        case mount(String)
        case eject(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var unmountFailure: (any Error)?
    private var mountFailure: (any Error)?
    private var ejectFailure: (any Error)?

    public init(unmountError: (any Error)? = nil, mountError: (any Error)? = nil, ejectError: (any Error)? = nil) {
        self.unmountFailure = unmountError
        self.mountFailure = mountError
        self.ejectFailure = ejectError
    }

    /// Every call that passed name validation, in order.
    public var calls: [Call] { lock.withLock { recorded } }

    public var unmountError: (any Error)? {
        get { lock.withLock { unmountFailure } }
        set { lock.withLock { unmountFailure = newValue } }
    }

    public var mountError: (any Error)? {
        get { lock.withLock { mountFailure } }
        set { lock.withLock { mountFailure = newValue } }
    }

    public var ejectError: (any Error)? {
        get { lock.withLock { ejectFailure } }
        set { lock.withLock { ejectFailure = newValue } }
    }

    public func unmountWholeDisk(bsdName: String) async throws {
        try record(.unmount(bsdName), bsdName: bsdName, failure: \.unmountFailure)
    }

    public func mountWholeDisk(bsdName: String) async throws {
        try record(.mount(bsdName), bsdName: bsdName, failure: \.mountFailure)
    }

    public func eject(bsdName: String) async throws {
        try record(.eject(bsdName), bsdName: bsdName, failure: \.ejectFailure)
    }

    private func record(_ call: Call, bsdName: String, failure: KeyPath<FakeDiskManager, (any Error)?>) throws {
        // Same name rule as production, so callers can't rely on the fake being lax.
        guard BSDName.isWholeDisk(bsdName) else { throw DiskManagerError.invalidDiskName(bsdName) }
        let error = lock.withLock { () -> (any Error)? in
            recorded.append(call)
            return self[keyPath: failure]
        }
        if let error { throw error }
    }
}
#endif
