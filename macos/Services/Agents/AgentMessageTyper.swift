import Foundation

/// Types a message into an agent's prompt the way a person would, for the chat and for Cascade
/// Remote alike. `clear` runs before every write and throws to stop: the agent may put up a
/// question between one key and the next.
enum AgentMessageTyper {
    @MainActor
    static func type(_ text: String, files: [ChatAttachment], into terminal: TerminalSession,
                     clear: @MainActor () async throws -> Void) async throws {
        // A message ending in an @ mention gets a space, which closes the file list the
        // CLI opened for it: Enter on that list picks a file instead of sending.
        let text = ChatCompletion.endsInMention(text) ? text + " " : text
        // A command must open the line, so its files follow it, as its arguments. Any
        // other message has them go first, pasted as a drop onto the terminal pastes
        // them, so the agent attaches them before the message is typed after them.
        let command = text.hasPrefix("/")
        let joined = files.map(\.path).joined(separator: " ")
        // Everything is checked before anything is typed, so a message the terminal
        // refuses leaves nothing half-written in the agent's prompt.
        let paths = try files.isEmpty ? nil : TerminalSession.paste(command ? " " + joined : joined + " ")
        let pasted = try text.isEmpty ? nil : TerminalSession.paste(text)
        let multiline = text.contains("\n")
        if let paths, !command {
            try await clear()
            try await terminal.writeAgentInput(paths)
            try await Task.sleep(for: .milliseconds(600))
        }
        // One line is typed like the agent controls type a command. Several need a
        // bracketed paste, and Claude Code takes an Enter that follows a paste closely
        // as part of it, so that Enter waits until the paste has settled.
        if let pasted {
            try await clear()
            try await terminal.writeAgentInput(multiline ? pasted : text)
            try await Task.sleep(for: .milliseconds(multiline ? 600 : 60))
        }
        if let paths, command {
            try await clear()
            try await terminal.writeAgentInput(paths)
            try await Task.sleep(for: .milliseconds(600))
        }
        try await clear()
        try await terminal.writeAgentInput("\r")
    }
}
