import Foundation

/// Runs diskutil's plist commands and decodes their output. Every target is validated
/// before it reaches the command line.
struct Diskutil: Sendable {
    static let path = "/usr/sbin/diskutil"

    let runner: any CommandRunner

    func list() async throws -> DiskutilList {
        try await decode(DiskutilList.self, arguments: ["list", "-plist"])
    }

    /// `target` is `/` or a device identifier such as `disk4` or `disk0s2`.
    func info(_ target: String) async throws -> DiskutilInfo {
        guard target == "/" || BSDName.isDeviceIdentifier(target) else {
            throw DiskDiscoveryError.invalidIdentifier(target)
        }
        return try await decode(DiskutilInfo.self, arguments: ["info", "-plist", target])
    }

    private func decode<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        let result = try await runner.run(Self.path, arguments: arguments)
        let command = (["diskutil"] + arguments).joined(separator: " ")
        // With -plist, diskutil reports failures as a plist on stdout (Error, ErrorMessage).
        let reply = try? PropertyListDecoder().decode(ErrorReply.self, from: result.stdout)
        if result.status != 0 || reply?.error == true {
            let message = reply?.message ?? result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskDiscoveryError.commandFailed(command: command, status: result.status, message: message)
        }
        do {
            return try PropertyListDecoder().decode(T.self, from: result.stdout)
        } catch {
            throw DiskDiscoveryError.malformedOutput(command: command, detail: String(describing: error))
        }
    }

    private struct ErrorReply: Decodable {
        var error: Bool?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case error = "Error"
            case message = "ErrorMessage"
        }
    }
}
