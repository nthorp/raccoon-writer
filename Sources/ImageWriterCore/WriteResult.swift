import Foundation

/// The outcome of a completed, flushed write.
public struct WriteResult: Equatable, Sendable {
    /// Image bytes written; the zero padding of the final block is not counted.
    public var bytesWritten: UInt64
    public var syncMethod: SyncMethod
    public var elapsedSeconds: TimeInterval

    public init(bytesWritten: UInt64, syncMethod: SyncMethod, elapsedSeconds: TimeInterval) {
        self.bytesWritten = bytesWritten
        self.syncMethod = syncMethod
        self.elapsedSeconds = elapsedSeconds
    }
}
