import Foundation

struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var combinedText: String {
        (String(data: stdout, encoding: .utf8) ?? "") + (String(data: stderr, encoding: .utf8) ?? "")
    }
}

/// Runs a tool with an argument array (never a shell string).
func runCommand(_ path: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Drain before waiting so a large plist cannot fill the pipe and deadlock.
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func runChecked(_ path: String, _ arguments: [String]) throws -> CommandResult {
    let result = try runCommand(path, arguments)
    guard result.status == 0 else {
        let command = ([path] + arguments).joined(separator: " ")
        throw SpikeError.commandFailed(command, status: result.status, output: result.combinedText)
    }
    return result
}

func plistDictionary(_ path: String, _ arguments: [String]) throws -> [String: Any] {
    let result = try runChecked(path, arguments)
    let object = try PropertyListSerialization.propertyList(from: result.stdout, format: nil)
    guard let dictionary = object as? [String: Any] else {
        throw SpikeError.plistParse(([path] + arguments).joined(separator: " "))
    }
    return dictionary
}
