import Foundation

/// Validation for BSD disk names before they reach a command line or device path.
public enum BSDName {
    /// True only for whole-disk names matching `^disk[0-9]+$`, ASCII digits only.
    /// Checked byte-wise because `Character.isNumber` accepts non-ASCII digits.
    public static func isWholeDisk(_ name: String) -> Bool {
        name.utf8.count <= 16 && digitGroups(name) == 1
    }

    /// True for whole disks and their slices, `^disk[0-9]+(s[0-9]+)*$` (`disk4`, `disk0s2`,
    /// `disk3s3s1`). Only for read-only queries such as `diskutil info`; device opens
    /// and unmounts take whole disks only.
    public static func isDeviceIdentifier(_ name: String) -> Bool {
        digitGroups(name) != nil
    }

    /// The number of `s`-separated ASCII digit groups after `disk`, or nil if malformed.
    private static func digitGroups(_ name: String) -> Int? {
        let bytes = Array(name.utf8)
        let prefix = Array("disk".utf8)
        guard bytes.count > prefix.count, bytes.count <= 32, bytes.starts(with: prefix) else { return nil }
        let groups = bytes.dropFirst(prefix.count).split(separator: UInt8(ascii: "s"), omittingEmptySubsequences: false)
        let valid = groups.allSatisfy { group in
            !group.isEmpty && group.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        }
        return valid ? groups.count : nil
    }
}
