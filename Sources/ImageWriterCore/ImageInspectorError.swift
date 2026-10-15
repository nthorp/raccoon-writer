import Foundation

/// Reasons a chosen file cannot be used as an image. Nothing has been written when these occur.
public enum ImageInspectorError: Error, Equatable, Sendable {
    case notAFileURL(String)
    case unsupportedExtension(fileName: String)
    /// A `.dmg` or `.udif`. Has its own case because the open panel offers these: macOS gives
    /// `.img` the same type as `.dmg`, so the panel can't filter them out.
    case macDiskImage(fileName: String)
    case notFound(fileName: String)
    case isDirectory(fileName: String)
    /// A device node, FIFO, socket or similar.
    case notRegularFile(fileName: String)
    case permissionDenied(fileName: String)
    case empty(fileName: String)
    case posix(operation: String, fileName: String, code: Int32)
}

extension ImageInspectorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAFileURL(let url):
            return "\(url) is not a local file."
        case .unsupportedExtension(let name):
            return "“\(name)” is not an .iso or .img file."
        case .macDiskImage(let name):
            return "“\(name)” is a macOS disk image, made to be opened on a Mac rather than copied onto a drive. Choose an .iso or .img file."
        case .notFound(let name):
            return "“\(name)” could not be found."
        case .isDirectory(let name):
            return "“\(name)” is a folder, not an image file."
        case .notRegularFile(let name):
            return "“\(name)” is not a regular file."
        case .permissionDenied(let name):
            return "You do not have permission to read “\(name)”."
        case .empty(let name):
            return "“\(name)” is empty."
        case .posix(let operation, let name, let code):
            return "Could not \(operation) “\(name)”: \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}
