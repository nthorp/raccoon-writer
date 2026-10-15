import Foundation
import os

/// Production `DiskManager`: `diskutil unmountDisk`, `mountDisk` and `eject` on `/dev/diskN`.
/// These commands print text, not plists, so failures are recognized from their output.
public struct DiskutilDiskManager: DiskManager {
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "diskmanager")

    private let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func unmountWholeDisk(bsdName: String) async throws {
        // An already-unmounted disk exits 0 with the usual success line, so this is idempotent.
        try await run("unmountDisk", bsdName: bsdName)
    }

    public func mountWholeDisk(bsdName: String) async throws {
        try await run("mountDisk", bsdName: bsdName)
    }

    public func eject(bsdName: String) async throws {
        try await run("eject", bsdName: bsdName)
    }

    private func run(_ verb: String, bsdName: String) async throws {
        guard BSDName.isWholeDisk(bsdName) else { throw DiskManagerError.invalidDiskName(bsdName) }
        let target = "/dev/\(bsdName)"
        let result = try await runner.run(Diskutil.path, arguments: [verb, target])
        guard result.status != 0 else { return }
        let output = [result.stdoutText, result.stderrText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        Self.log.error("diskutil \(verb, privacy: .public) \(target, privacy: .public) exited \(result.status): \(output, privacy: .public)")
        throw Self.failure(command: "diskutil \(verb) \(target)", status: result.status, output: output, bsdName: bsdName)
    }

    /// Maps a failed diskutil run to a typed error. Texts seen on macOS 26.3.1:
    /// - busy (unmountDisk and eject): "Unmount of disk7 failed: at least one volume could
    ///   not be unmounted" then "Unmount was dissented by PID 57474 (/bin/sleep)"
    /// - missing disk, unmountDisk: "Unmount failed for /dev/disk7" and nothing else
    /// - missing disk, eject: "Failed to find disk /dev/disk7"
    static func failure(command: String, status: Int32, output: String, bsdName: String) -> DiskManagerError {
        let lowered = output.lowercased()
        if lowered.contains("dissented by") || lowered.contains("could not be unmounted") || lowered.contains("busy") {
            return .busy(dissenter: dissenter(in: output))
        }
        let notFoundPhrases = ["failed to find disk", "unable to find disk", "could not find disk"]
        if notFoundPhrases.contains(where: lowered.contains) || output == "Unmount failed for /dev/\(bsdName)" {
            return .notFound(bsdName: bsdName)
        }
        return .commandFailed(command: command, status: status, output: output)
    }

    /// The process path from a line like "Unmount was dissented by PID 57474 (/bin/sleep)".
    static func dissenter(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "dissented by PID ", options: .caseInsensitive),
                  let open = line[marker.upperBound...].firstIndex(of: "("),
                  let close = line.lastIndex(of: ")"), open < close else { continue }
            let path = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return path }
        }
        return nil
    }
}
