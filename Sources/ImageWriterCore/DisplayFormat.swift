import Foundation

/// Text for sizes, speeds and times on screen. Decimal units, as Finder uses, and a
/// fixed `.` decimal separator so the output doesn't depend on the test machine's locale
/// (the app is not localized in v1).
public enum DisplayFormat {
    private static let units = ["KB", "MB", "GB", "TB", "PB"]

    /// "512 bytes", "4.7 GB", "31 GB", "128 GB".
    public static func size(_ bytes: UInt64) -> String {
        guard bytes >= 1000 else { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes) / 1000
        var unit = 0
        // Compare against the rounded value so 999.96 KB reads "1 MB", not "1000 KB".
        while unit < units.count - 1, rounded(value) >= 1000 {
            value /= 1000
            unit += 1
        }
        return "\(number(value)) \(units[unit])"
    }

    /// "38.2 MB/s"; "—" while the speed is still unknown.
    public static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return "\(size(UInt64(bytesPerSecond.rounded())))/s"
    }

    /// "42 %". Never shows 100 % before the pass is really complete.
    public static func percent(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        var whole = Int((clamped * 100).rounded(.down))
        if clamped >= 1 { whole = 100 }
        return "\(whole) %"
    }

    /// "8 s", "3 min 05 s", "1 h 02 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours) h \(twoDigits(minutes)) min" }
        if minutes > 0 { return "\(minutes) min \(twoDigits(secs)) s" }
        return "\(secs) s"
    }

    /// "About 3 min left", rounded up to whole minutes above a minute; "—" while unknown.
    public static func remaining(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(duration(Double(minutes) * 60)) left"
    }

    /// Mounted volumes for the confirm screen: "/Volumes/STICK, /Volumes/DATA" or "none".
    public static func mountPoints(of disk: DiskInfo) -> String {
        disk.mountPoints.isEmpty ? "none" : disk.mountPoints.joined(separator: ", ")
    }

    /// Volume names as diskutil lists them, mounted or not: "STICK, DATA". Nil when the
    /// drive has none, so callers can leave the name out rather than show a placeholder.
    public static func volumeNames(of disk: DiskInfo) -> String? {
        disk.volumeNames.isEmpty ? nil : disk.volumeNames.joined(separator: ", ")
    }

    private static func rounded(_ value: Double) -> Double {
        value < 100 ? (value * 10).rounded() / 10 : value.rounded()
    }

    /// One decimal below 100, none above, and no trailing ".0".
    private static func number(_ value: Double) -> String {
        let r = rounded(value)
        if r < 100, r != r.rounded() {
            return String(format: "%.1f", r)
        }
        return String(format: "%.0f", r)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
