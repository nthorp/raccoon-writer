import UniformTypeIdentifiers

enum ImageFileTypes {
    /// What the open panel offers. `ImageInspector` still checks the extension itself.
    static let allowed: [UTType] = ["iso", "img"].compactMap { UTType(filenameExtension: $0) }
}
