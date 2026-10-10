import Foundation

/// A run that stopped on an error, with the stage it stopped in.
public struct WriteFailure: Error, Sendable {
    public var stage: PipelineStage
    /// The typed error from that stage (`SafetyGuardError`, `DiskManagerError`,
    /// `DeviceOpenError`, `WriteEngineError`, `VerifierError`, `ImageSourceError`, …).
    public var error: any Error

    public init(stage: PipelineStage, error: any Error) {
        self.stage = stage
        self.error = error
    }

    public var message: String { error.localizedDescription }
}

extension WriteFailure: Equatable {
    // Errors aren't Equatable in general, so two failures match when the stage and the
    // error's full description (type, case and payload) do.
    public static func == (lhs: WriteFailure, rhs: WriteFailure) -> Bool {
        lhs.stage == rhs.stage && String(reflecting: lhs.error) == String(reflecting: rhs.error)
    }
}

extension WriteFailure: LocalizedError {
    public var errorDescription: String? { message }
}
