import Foundation

/// A slash command as `/api/agent/commands` lists it: the CLI's built-ins, and the commands, skills
/// and plugins it reads from disk.
struct AgentCommand: Decodable, Equatable, Sendable {
    let name: String
    let description: String
    /// The arguments it takes, as the command describes them (`<branch>`); empty for none.
    let hint: String
    /// `project`, `user`, `plugin` or `builtin`.
    let source: String
    let plugin: String?
    /// Sent without arguments it opens a panel in the terminal instead of answering in the chat.
    let interactive: Bool
}

/// One row of the list over the message field: a command to run, or a file to mention.
struct ChatSuggestion: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case command, file }
    let kind: Kind
    /// As the field will show it: `/review`, `@src/main.rs`.
    let title: String
    let detail: String
    /// Where it comes from: Project, Personal, a plugin's name; nothing for a built-in or a file.
    let badge: String?
    /// What replaces the word being completed, with the space that ends it.
    let insert: String
    /// A command that runs as it is: Enter on it sends at once, as Enter does in the terminal.
    let complete: Bool
    var id: String { title }
}

/// What the message field is completing, worked out from its text and caret alone. The field's
/// text carries each attached file as one `fileMark`.
enum ChatCompletion {
    /// An attached file's place in the message text. The field draws a chip for it.
    static let fileMark: Character = "\u{FFFC}"
    static let fileMarkUnit: unichar = 0xFFFC

    /// The word the caret is in, when it is one to complete.
    struct Word: Equatable {
        enum Kind: Equatable { case command, file }
        let kind: Kind
        /// What follows the `/` or `@`, up to the caret.
        let query: String
        /// The whole word, in UTF-16 units: this is what a suggestion replaces.
        let range: NSRange
    }

    /// A `/` word that opens the message (a command anywhere else is text to the CLI), or an `@`
    /// word anywhere. Neither is completed once a space ends it.
    static func word(in text: String, caret: Int) -> Word? {
        let text = text as NSString
        guard caret > 0, caret <= text.length else { return nil }
        var start = caret
        while start > 0, !ends(text.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < text.length, !ends(text.character(at: end)) { end += 1 }
        guard start < caret else { return nil }
        let typed = text.substring(with: NSRange(location: start, length: caret - start))
        let range = NSRange(location: start, length: end - start)
        if typed.hasPrefix("/") {
            let before = text.substring(to: start)
            guard before.allSatisfy(\.isWhitespace), !typed.dropFirst().contains("/") else { return nil }
            return Word(kind: .command, query: String(typed.dropFirst()), range: range)
        }
        if typed.hasPrefix("@") {
            return Word(kind: .file, query: String(typed.dropFirst()), range: range)
        }
        return nil
    }

    private static func ends(_ unit: unichar) -> Bool {
        if unit == fileMarkUnit { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Commands for `query`: names that start with it, then names with a part that does
    /// (`tools:deploy` for `dep`), then names and descriptions that hold it. Within each, the
    /// order the CLI's list gave.
    static func commands(_ all: [AgentCommand], matching query: String) -> [AgentCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        func rank(_ command: AgentCommand) -> Int? {
            let name = command.name.lowercased()
            if name.hasPrefix(query) { return 0 }
            if name.split(whereSeparator: { ":-_".contains($0) }).contains(where: { $0.hasPrefix(query) }) { return 1 }
            if name.contains(query) { return 2 }
            if command.description.lowercased().contains(query) { return 3 }
            return nil
        }
        return all.enumerated()
            .compactMap { index, command in rank(command).map { (rank: $0, index: index, command: command) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map { $0.command }
    }

    static func suggestion(for command: AgentCommand) -> ChatSuggestion {
        let badge: String? = switch command.source {
        case "project": String(localized: "Project")
        case "user": String(localized: "Personal")
        case "plugin": command.plugin ?? String(localized: "Plugin")
        default: nil
        }
        let title = "/" + command.name
        return ChatSuggestion(kind: .command, title: title,
                              detail: [command.hint, command.description].filter { !$0.isEmpty }.joined(separator: "  "),
                              badge: badge, insert: title + " ", complete: command.hint.isEmpty)
    }

    static func suggestion(forFile path: String) -> ChatSuggestion {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        // A path with a space would end the word; the CLIs read the escaped form.
        let mention = "@" + TerminalPastePayload.escape(path)
        return ChatSuggestion(kind: .file, title: mention, detail: folder.isEmpty ? name : folder,
                              badge: nil, insert: mention + " ", complete: false)
    }

    /// The message as the terminal gets it: the text without its files' marks, which go ahead of it
    /// as pasted paths.
    static func text(of draft: String) -> String {
        draft.filter { $0 != fileMark }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the message ends in an `@` mention. Its last word is taken back to a space that is
    /// not escaped, since a mentioned path's own spaces are.
    static func endsInMention(_ text: String) -> Bool {
        let characters = Array(text)
        var start = characters.count
        while start > 0, !(characters[start - 1].isWhitespace && (start < 2 || characters[start - 2] != "\\")) { start -= 1 }
        return start < characters.count && characters[start] == "@"
    }

    static func markCount(in draft: String) -> Int { draft.reduce(0) { $0 + ($1 == fileMark ? 1 : 0) } }

    /// The UTF-16 offset of each file's mark, in order.
    static func markOffsets(in draft: String) -> [Int] {
        let units = Array(draft.utf16)
        return units.indices.filter { units[$0] == fileMarkUnit }
    }
}
