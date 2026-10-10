import Foundation

/// Failures reading the image file during a write or verify.
public enum ImageSourceError: Error, Equatable, Sendable {
    /// The file's size or type differs from when it was selected.
    case changed(fileName: String)
    /// The file ended before its selected size, so it was truncated while in use.
    case truncated(fileName: String, atOffset: UInt64)
    case posix(operation: String, fileName: String, code: Int32)
}

extension ImageSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .changed(let name):
            return "“\(name)” changed after it was selected."
        case .truncated(let name, let offset):
            return "“\(name)” became shorter while it was being read (at byte \(offset))."
        case .posix(let operation, let name, let code):
            return "Could not \(operation) “\(name)”: \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}
