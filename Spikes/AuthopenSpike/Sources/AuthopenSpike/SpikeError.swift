import Foundation

enum SpikeError: Error, CustomStringConvertible {
    case usage(String)
    case refused(String)
    case commandFailed(String, status: Int32, output: String)
    case plistParse(String)
    case posix(String, errno: Int32)
    case noDescriptorReceived
    case authopenExited(status: Int32)
    case authopenSignalled(signal: Int32)
    case mismatch(offset: Int)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .refused(let reason):
            return "REFUSED: \(reason)"
        case .commandFailed(let command, let status, let output):
            return "\(command) exited with status \(status): \(output)"
        case .plistParse(let what):
            return "could not parse plist from \(what)"
        case .posix(let call, let code):
            return "\(call) failed: errno \(code) (\(String(cString: strerror(code))))"
        case .noDescriptorReceived:
            return "authopen closed the socket without sending a file descriptor"
        case .authopenExited(let status):
            return "authopen exited with status \(status) (no fd)"
        case .authopenSignalled(let signal):
            return "authopen was killed by signal \(signal)"
        case .mismatch(let offset):
            return "read-back mismatch at byte offset \(offset)"
        }
    }
}
