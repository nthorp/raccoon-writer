import Foundation

/// What the done screen reports after a written, verified run.
public struct WriteSummary: Equatable, Sendable {
    public var imageName: String
    public var driveName: String
    public var bsdName: String
    /// Image bytes written and verified.
    public var bytes: UInt64
    public var writeSeconds: TimeInterval
    public var verifySeconds: TimeInterval
    /// From "Erase and Write" to the end of the eject.
    public var totalSeconds: TimeInterval
    public var syncMethod: SyncMethod
    /// Set when the drive was written and verified but could not be ejected.
    public var ejectWarning: EjectWarning?

    public init(
        imageName: String,
        driveName: String,
        bsdName: String,
        bytes: UInt64,
        writeSeconds: TimeInterval,
        verifySeconds: TimeInterval,
        totalSeconds: TimeInterval,
        syncMethod: SyncMethod,
        ejectWarning: EjectWarning?
    ) {
        self.imageName = imageName
        self.driveName = driveName
        self.bsdName = bsdName
        self.bytes = bytes
        self.writeSeconds = writeSeconds
        self.verifySeconds = verifySeconds
        self.totalSeconds = totalSeconds
        self.syncMethod = syncMethod
        self.ejectWarning = ejectWarning
    }

    /// Average speed of the write pass, flush included. Nil if it took no measurable time.
    public var averageWriteBytesPerSecond: Double? {
        writeSeconds > 0 ? Double(bytes) / writeSeconds : nil
    }
}
