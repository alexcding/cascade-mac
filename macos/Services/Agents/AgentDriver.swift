import Foundation

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
/// session is launched, how its model is switched, and what its conversation commands are
/// called. The rest of the app holds a driver and never asks which CLI it is.
protocol AgentDriver: Sendable {
    var cli: String { get }
    func launchCommand(sessionID: String?, fresh: Bool, selection: AgentCatalog.Model?, effort: String?,
                       statusLine: AgentStatusLine?) -> String
    /// What to type at the running agent to move it to `model`, without leaving the conversation.
    /// Throws when the CLI has no way to get there.
    func switchInputs(to model: AgentCatalog.Model, effort: String?, in catalog: AgentCatalog) throws -> [AgentInput]
    var compactCommand: String { get }
    var clearCommand: String { get }
}

enum AgentDrivers {
    /// A session with no `cli` recorded runs Claude, as the backend assumes.
    static func driver(for cli: String?) -> any AgentDriver { cli == "codex" ? CodexDriver() : ClaudeDriver() }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

struct ClaudeDriver: AgentDriver {
    let cli = "claude"
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

    /// Claude Code takes both at its prompt, mid-conversation.
    func switchInputs(to model: AgentCatalog.Model, effort: String?, in catalog: AgentCatalog) throws -> [AgentInput] {
        [.line("/model \(model.alias)")] + (effort.map { [.line("/effort \($0)")] } ?? [])
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
