import Foundation

/// Validation for BSD disk names before they reach a command line or device path.
public enum BSDName {
    /// True only for whole-disk names matching `^disk[0-9]+$`, ASCII digits only.
    /// Checked byte-wise because `Character.isNumber` accepts non-ASCII digits.
    public static func isWholeDisk(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let prefix = Array("disk".utf8)
        guard bytes.count > prefix.count, bytes.count <= 16, bytes.starts(with: prefix) else { return false }
        return bytes.dropFirst(prefix.count).allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}
