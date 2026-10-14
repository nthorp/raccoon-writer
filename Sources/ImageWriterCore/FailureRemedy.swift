import Foundation

/// One way to fix a failure, listed on the failed screen.
public struct FailureRemedy: Equatable, Sendable {
    public var title: String
    public var instructions: String
    /// A Terminal command to show as selectable text, or nil.
    public var command: String?
    /// A caveat shown after the instructions, or nil.
    public var note: String?

    public init(title: String, instructions: String, command: String? = nil, note: String? = nil) {
        self.title = title
        self.instructions = instructions
        self.command = command
        self.note = note
    }
}
