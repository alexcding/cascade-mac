import AppKit
import SwiftUI

/// A model and effort pairing, by the ids the CLI's catalog lists.
struct AgentSelection: Codable, Equatable, Sendable {
    var model: String
    var effort: String?
}

/// What an agent CLI offers to switch to, as the backend's probe for it reports.
struct AgentCatalog: Decodable, Equatable, Sendable {
    struct Effort: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let name: String
    }
    struct Model: Decodable, Equatable, Identifiable, Sendable {
        /// What the CLI reports it is running.
        let id: String
        /// What the CLI accepts when asked to switch.
        let alias: String
        let name: String
        let efforts: [Effort]
        let defaultEffort: String?
    }
    var models: [Model] = []

    func model(_ id: String?) -> Model? { models.first { $0.id == id || $0.alias == id } }

    /// Whether `selection` is what the agent is running. One with no effort leaves it to the CLI,
    /// so whatever level the CLI reports is its, unless another preset names that very level.
    func selection(_ selection: AgentSelection, isRunning running: AgentSelection, among presets: [AgentPreset]) -> Bool {
        let runningModel = model(running.model)?.id ?? running.model
        func sameModel(_ other: AgentSelection) -> Bool { model(other.model)?.id == runningModel }
        guard sameModel(selection) else { return false }
        if selection.effort == running.effort { return true }
        return selection.effort == nil
            && !presets.contains { sameModel($0.selection) && $0.selection.effort == running.effort }
    }
}

/// What the agent is running right now. Every field is the CLI's own account, or absent.
struct AgentStatus: Decodable, Equatable, Sendable {
    let model: String?
    let effort: String?
    let tokens: Int
    let window: Int?
    let percent: Double?

    var fraction: Double? { percent.map { min(1, max(0, $0 / 100)) } }
}

/// One thing typed at a running agent.
enum AgentInput: Equatable, Sendable {
    /// Text entered at its prompt, followed by Return: a slash command.
    case line(String)
    /// A bare key press, with no Return: a choice in a menu the agent has opened.
    case key(String)
}

/// Where Claude Code should send its status line, so the app can read the real context window.
struct AgentStatusLine: Equatable, Sendable {
    let script: String
    let taskID: String
}

/// One per agent CLI. Everything the app does differently between CLIs is behind this: how a
/// session is launched, how its model is switched, what its conversation commands are called, and
/// how the app draws it. The rest of the app holds a driver and never asks which CLI it is. What
/// the backend knows of a CLI comes with its transcript instead (`AgentProfile`); the backend's
/// registry lists the same CLIs (`every_cli_the_native_app_starts_is_known_here`).
protocol AgentDriver: Sendable {
    /// Its id: what sessions, hooks and requests carry, and the backend's `Agent` answers to.
    var cli: String { get }
    /// Its name, as a person knows it.
    var name: String { get }
    /// The one-word form, for tight columns and pickers.
    var shortName: String { get }
    /// What the chat's empty message field reads.
    var chatPlaceholder: String { get }
    /// Its mark in the asset catalogue.
    var asset: String { get }
    /// Its brand colour, 0xRRGGBB, for what is that agent's and not the app's: its usage, its used
    /// context, its sidebar dot while it works. Not a palette colour, so it does not swap with the theme; it reads on
    /// light and dark.
    var brandColor: UInt32 { get }
    /// Its mark as a character, and a list row's face for it.
    var restingGlyph: String { get }
    var markGlyphFont: Font { get }
    var installationGuide: URL { get }
    /// The app names its conversation at launch, so a session keeps one conversation across
    /// restarts, and the app can check the CLI still has it before resuming it.
    var namesConversationAtLaunch: Bool { get }
    /// It runs the app's status line wrapper, which is how it reports its real context window.
    var takesStatusLine: Bool { get }
    /// What to tell a person after the app updated this CLI's hooks, which it may not use until
    /// they allow the change.
    var hooksChangedNotice: String { get }
    func launchCommand(sessionID: String?, fresh: Bool, selection: AgentCatalog.Model?, effort: String?,
                       statusLine: AgentStatusLine?) -> String
    /// Starts a fork of the conversation `source` names, as this CLI's adapter in the backend gives
    /// it: a new conversation, `sessionID` when the app names it, that begins with all of the
    /// source's and works in `directory`, the fork's worktree, not the source's. The source's own
    /// conversation is left as it was.
    func forkCommand(from source: String, in directory: String, sessionID: String?, statusLine: AgentStatusLine?) -> String
    /// The conversation a fork's `source` is, so the app can ask whether the CLI still has it.
    func forkedConversation(_ source: String) -> String
    /// What to type at the running agent to move it to `model`, without leaving the conversation.
    /// Throws when the CLI has no way to get there.
    func switchInputs(to model: AgentCatalog.Model, effort: String?, in catalog: AgentCatalog) throws -> [AgentInput]
    var compactCommand: String { get }
    var clearCommand: String { get }
}

enum AgentDrivers {
    /// Every agent CLI the app runs, in the order it offers them. The first is the default.
    static let all: [any AgentDriver] = [ClaudeDriver(), CodexDriver()]
    static var primary: any AgentDriver { all[0] }
    /// The CLI with this id; nil for a plain shell or a CLI the app does not run.
    static func of(_ cli: String?) -> (any AgentDriver)? { all.first { $0.cli == cli } }
    /// A session with no `cli` recorded runs the default CLI, as the backend assumes.
    static func driver(for cli: String?) -> any AgentDriver { of(cli) ?? primary }
    /// Each CLI as (id, short name), for pickers of one agent's usage.
    static var choices: [(key: String, title: String)] { all.map { ($0.cli, $0.shortName) } }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

extension AgentDriver {
    var tint: Color { Color(nsColor: sidebarTint) }
    var sidebarTint: NSColor {
        NSColor(srgbRed: CGFloat(brandColor >> 16 & 0xff) / 255, green: CGFloat(brandColor >> 8 & 0xff) / 255,
                blue: CGFloat(brandColor & 0xff) / 255, alpha: 1)
    }
}

struct ClaudeDriver: AgentDriver {
    let cli = "claude"
    let name = "Claude Code"
    let shortName = "Claude"
    var chatPlaceholder: String { String(localized: "Ask Claude") }
    let asset = "AgentClaude"
    let brandColor: UInt32 = 0xd97757
    /// Claude Code's own asterisk in full bloom.
    let restingGlyph = "✻"
    var markGlyphFont: Font { .system(size: 14, weight: .ultraLight) }
    let installationGuide = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
    /// `--session-id` takes an id the app chooses, and `--resume` finds it again.
    let namesConversationAtLaunch = true
    /// `--settings` gives it a status line for this launch only.
    let takesStatusLine = true
    /// It holds hooks changed outside it until they are reviewed in its `/hooks` menu.
    var hooksChangedNotice: String { String(localized: "Claude Code may ask you to review the change: allow it in /hooks.") }
    let compactCommand = "/compact"
    let clearCommand = "/clear"

    func launchCommand(sessionID: String?, fresh: Bool, selection: AgentCatalog.Model?, effort: String?,
                       statusLine: AgentStatusLine?) -> String {
        var parts = ["claude"]
        if let id = sessionID, !id.isEmpty { parts += [fresh ? "--session-id" : "--resume", AgentDrivers.quote(id)] }
        if let selection { parts += ["--model", AgentDrivers.quote(selection.alias)] }
        if let effort { parts += ["--effort", AgentDrivers.quote(effort)] }
        if let statusLine, let settings = Self.settings(statusLine) { parts += ["--settings", AgentDrivers.quote(settings)] }
        return parts.joined(separator: " ")
    }

    /// `--resume` takes the source's transcript path, which finds it from the fork's own folder,
    /// and `--fork-session` keeps it as it was, writing on under `--session-id` instead.
    func forkCommand(from source: String, in directory: String, sessionID: String?, statusLine: AgentStatusLine?) -> String {
        var parts = ["claude"]
        if let id = sessionID, !id.isEmpty { parts += ["--session-id", AgentDrivers.quote(id)] }
        parts += ["--fork-session", "--resume", AgentDrivers.quote(source)]
        if let statusLine, let settings = Self.settings(statusLine) { parts += ["--settings", AgentDrivers.quote(settings)] }
        return parts.joined(separator: " ")
    }
    /// The transcript is named by the conversation's id.
    func forkedConversation(_ source: String) -> String {
        ((source as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Claude Code takes both at its prompt, mid-conversation.
    func switchInputs(to model: AgentCatalog.Model, effort: String?, in catalog: AgentCatalog) throws -> [AgentInput] {
        // No effort is Claude's own choice again: `/model` alone would keep the level it is at.
        let level = effort ?? (model.efforts.isEmpty ? nil : "auto")
        return [.line("/model \(model.alias)")] + (level.map { [.line("/effort \($0)")] } ?? [])
    }

    /// Settings for this launch only: the user's own settings file is never written.
    private static func settings(_ line: AgentStatusLine) -> String? {
        let command = "/bin/sh \(AgentDrivers.quote(line.script)) \(AgentDrivers.quote(line.taskID))"
        let value = ["statusLine": ["type": "command", "command": command]]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct CodexDriver: AgentDriver {
    let cli = "codex"
    let name = "Codex"
    let shortName = "Codex"
    var chatPlaceholder: String { String(localized: "Ask Codex") }
    let asset = "AgentCodex"
    let brandColor: UInt32 = 0x707af0
    let restingGlyph = "⠿"
    var markGlyphFont: Font { .system(size: 16) }
    let installationGuide = URL(string: "https://github.com/openai/codex")!
    /// It names its own sessions, and `resume` takes the one it reports.
    let namesConversationAtLaunch = false
    let takesStatusLine = false
    var hooksChangedNotice: String { String(localized: "Codex may ask you to review the change before it uses them.") }
    let compactCommand = "/compact"
    let clearCommand = "/clear"

    func launchCommand(sessionID: String?, fresh: Bool, selection: AgentCatalog.Model?, effort: String?,
                       statusLine: AgentStatusLine?) -> String {
        var parts = ["codex"]
        if let id = sessionID, !id.isEmpty { parts += ["resume", AgentDrivers.quote(id)] }
        if let selection { parts += ["-m", AgentDrivers.quote(selection.alias)] }
        if let effort { parts += ["-c", AgentDrivers.quote("model_reasoning_effort=\"\(effort)\"")] }
        return parts.joined(separator: " ")
    }

    /// `codex fork` takes the source's id and names the new conversation itself; its hooks report it.
    /// Without `-C` it offers to go back to the directory the source ran in, and that is its default.
    func forkCommand(from source: String, in directory: String, sessionID: String?, statusLine: AgentStatusLine?) -> String {
        ["codex", "fork", "-C", AgentDrivers.quote(directory), AgentDrivers.quote(source)].joined(separator: " ")
    }
    func forkedConversation(_ source: String) -> String { source }

    /// Codex's `/model` takes no argument: typed text after it goes to the model as a prompt. It
    /// opens a numbered picker instead, models in catalog order and then the model's reasoning
    /// levels, and a digit chooses a row. Max and Ultra sit one level down, behind the row after
    /// the ordinary levels. Every press is a digit, never Return, so if the picker failed to open
    /// the digits land in the prompt as text and nothing is sent.
    func switchInputs(to model: AgentCatalog.Model, effort: String?, in catalog: AgentCatalog) throws -> [AgentInput] {
        guard let row = catalog.models.firstIndex(where: { $0.id == model.id }), row < 9 else {
            throw BackendError.operation("\(model.name) is not in Codex’s model picker.")
        }
        let advanced: Set<String> = ["max", "ultra"]
        let ordinary = model.efforts.filter { !advanced.contains($0.id) }
        let deeper = model.efforts.filter { advanced.contains($0.id) }
        guard let level = effort ?? model.defaultEffort else {
            throw BackendError.operation("Choose a reasoning level for \(model.name).")
        }
        var inputs: [AgentInput] = [.line("/model"), .key("\(row + 1)")]
        if let index = ordinary.firstIndex(where: { $0.id == level }) {
            inputs.append(.key("\(index + 1)"))
        } else if let index = deeper.firstIndex(where: { $0.id == level }) {
            inputs += [.key("\(ordinary.count + 1)"), .key("\(index + 1)")]
        } else {
            throw BackendError.operation("\(model.name) has no \(level) reasoning level.")
        }
        return inputs
    }
}
