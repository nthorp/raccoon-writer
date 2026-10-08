import Foundation

/// Failures to run a command at all. A command that runs and exits nonzero is not one of these.
public enum CommandRunnerError: Error, Equatable, Sendable {
    case launchFailed(executable: String, message: String)
    /// The command did not finish in time and was terminated.
    case timedOut(executable: String, seconds: Double)
    /// The command was killed by a signal we did not send.
    case terminated(executable: String, signal: Int32)
    case outputUnreadable(executable: String, message: String)
}

extension CommandRunnerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let message):
            return "Could not run \(executable): \(message)"
        case .timedOut(let executable, let seconds):
            return "\(executable) did not respond within \(Int(seconds.rounded())) seconds."
        case .terminated(let executable, let signal):
            return "\(executable) was terminated by signal \(signal)."
        case .outputUnreadable(let executable, let message):
            return "Could not read the output of \(executable): \(message)"
        }
    }
}
