import Foundation
import SwiftUI
import Testing
@testable import Cascade

@Suite struct AgentDriverTests {
    private let opus = AgentCatalog.Model(id: "claude-opus-5", alias: "opus", name: "Opus 5",
                                          efforts: [.init(id: "high", name: "High")], defaultEffort: "high")
    private static func levels(_ ids: [String]) -> [AgentCatalog.Effort] { ids.map { .init(id: $0, name: $0) } }
    private let astra = AgentCatalog.Model(id: "gpt-6-astra", alias: "gpt-6-astra", name: "GPT-6-Astra",
                                           efforts: levels(["low", "medium", "high", "xhigh", "max", "ultra"]), defaultEffort: "medium")
    private let older = AgentCatalog.Model(id: "gpt-5.5", alias: "gpt-5.5", name: "GPT-5.5",
                                           efforts: levels(["low", "medium", "high", "xhigh"]), defaultEffort: "medium")

    @Test func aPresetWithNoEffortRunsAtAnyLevelNoOtherPresetNames() {
        let catalog = AgentCatalog(models: [opus, astra])
        let loose = AgentSelection(model: "opus", effort: nil), fixed = AgentSelection(model: "claude-opus-5", effort: "high")
        let running = AgentSelection(model: "claude-opus-5", effort: "medium")
        #expect(catalog.selection(loose, isRunning: running, among: [AgentPreset(selection: loose)]))
        #expect(!catalog.selection(AgentSelection(model: "gpt-6-astra", effort: nil), isRunning: running, among: []),
                "Another model is not running")
        let both = [AgentPreset(selection: loose), AgentPreset(selection: fixed)]
        let atHigh = AgentSelection(model: "claude-opus-5", effort: "high")
        #expect(catalog.selection(fixed, isRunning: atHigh, among: both))
        #expect(!catalog.selection(loose, isRunning: atHigh, among: both), "The preset that names the level is the one running")
        #expect(catalog.selection(loose, isRunning: running, among: both))
    }

    @Test func claudeSwitchesAtItsPromptByAlias() throws {
        let driver = AgentDrivers.driver(for: nil)
        let catalog = AgentCatalog(models: [opus])
        #expect(driver.cli == "claude")
        #expect(try driver.switchInputs(to: opus, effort: "high", in: catalog) == [.line("/model opus"), .line("/effort high")])
        #expect(try driver.switchInputs(to: opus, effort: nil, in: catalog) == [.line("/model opus"), .line("/effort auto")],
                "No effort hands the level back to Claude")
        let haiku = AgentCatalog.Model(id: "claude-haiku-4-5", alias: "haiku", name: "Haiku 4.5", efforts: [], defaultEffort: nil)
        #expect(try driver.switchInputs(to: haiku, effort: nil, in: catalog) == [.line("/model haiku")])
    }

    @Test func claudeLaunchCarriesTheStatusLineWithoutTouchingUserSettings() throws {
        let line = AgentStatusLine(script: "/Apps/Cascade Dev.app/it's.sh", taskID: "task-1")
        let command = ClaudeDriver().launchCommand(sessionID: "new", fresh: true, selection: nil, effort: nil, statusLine: line)
        #expect(command.hasPrefix("claude --session-id 'new' --settings '"))
        // Undo the shell quoting: what Claude receives must be the JSON naming the wrapper and task.
        let quoted = String(command.dropFirst("claude --session-id 'new' --settings ".count))
        let json = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        let value = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]])
        #expect(value["statusLine"]?["type"] == "command")
        #expect(value["statusLine"]?["command"] == "/bin/sh '/Apps/Cascade Dev.app/it'\"'\"'s.sh' 'task-1'")
    }

    /// A fork's first launch copies the source's conversation under the fork's own id, and still
    /// takes the composer's prompt; without a source it is an ordinary launch.
    @Test func aForkLaunchCopiesTheSourceConversationUnderItsOwnID() {
        let claude = SessionAgent.claude.command(sessionID: "new", fresh: true,
                                                 forking: ("/h/.claude/projects/-r-a/old's.jsonl", "/r/b"))
        #expect(claude == "claude --session-id 'new' --fork-session --resume '/h/.claude/projects/-r-a/old'\"'\"'s.jsonl'")
        // Codex would otherwise offer the source's directory, and default to it.
        #expect(SessionAgent.codex.command(sessionID: nil, fresh: true, prompt: "go on", forking: ("019a-old", "/r/b 2"))
                == "codex fork -C '/r/b 2' '019a-old' 'go on'")
        #expect(SessionAgent.claude.command(sessionID: "new", fresh: true, forking: nil) == "claude --session-id 'new'")
        #expect(SessionAgent.shell.command(sessionID: nil, forking: ("old", "/r/b")) == nil)
        // Whether the source is still there is asked of the conversation it names.
        #expect(ClaudeDriver().forkedConversation("/h/.claude/projects/-r-a/0f3c-old.jsonl") == "0f3c-old")
        #expect(CodexDriver().forkedConversation("019a-old") == "019a-old")
    }

    /// The rows as Codex 0.155 draws them: models in catalog order, the ordinary levels, then
    /// "More reasoning…" holding Max and Ultra.
    @Test func codexSwitchesByChoosingRowsInItsPickerAndNeverPressesReturnThere() throws {
        let driver = AgentDrivers.driver(for: "codex")
        let catalog = AgentCatalog(models: [astra, older])
        #expect(try driver.switchInputs(to: older, effort: "high", in: catalog) == [.line("/model"), .key("2"), .key("3")])
        #expect(try driver.switchInputs(to: astra, effort: "ultra", in: catalog) == [.line("/model"), .key("1"), .key("5"), .key("2")])
        #expect(try driver.switchInputs(to: astra, effort: nil, in: catalog) == [.line("/model"), .key("1"), .key("2")])
        #expect(throws: (any Error).self) { try driver.switchInputs(to: older, effort: "max", in: catalog) }
        #expect(throws: (any Error).self) { try driver.switchInputs(to: opus, effort: "high", in: catalog) }
    }

    @Test func presetsDropGoneModelsAndFallBackToTheCatalogWhenNoneAreLeft() {
        let catalog = AgentCatalog(models: [opus, astra])
        var list = AgentPresetList()
        #expect(list.resolved(in: catalog).map(\.selection) == [.init(model: "claude-opus-5", effort: "high"), .init(model: "gpt-6-astra", effort: "medium")])
        // The stand-ins are the same rows on every render.
        #expect(list.resolved(in: catalog) == list.resolved(in: catalog))
        let kept = AgentPreset(selection: .init(model: "opus", effort: "high"),
                               shortcut: AgentShortcut(key: "1", command: true, control: true))
        list.presets = [kept, AgentPreset(selection: .init(model: "retired-model", effort: "low"))]
        #expect(list.resolved(in: catalog) == [kept])
        list.presets = [AgentPreset(selection: .init(model: "retired-model", effort: "low"))]
        #expect(list.resolved(in: catalog).count == 2)
        list.presets = [kept]
        #expect(AgentPresetList(rawValue: list.rawValue) == list)
        #expect(kept.shortcut?.title == "⌃⌘1")
        #expect(kept.shortcut?.keyboardShortcut == KeyboardShortcut("1", modifiers: [.command, .control]))
    }

    /// The context readout's title is the percentage whenever the agent reports one, and its help
    /// never says there is no percentage while the title shows one.
    @Test func theContextReadoutAgreesWithItsHelp() {
        let full = AgentStatus(model: nil, effort: nil, tokens: 45_000, window: 200_000, percent: 22.5)
        #expect(full.contextTitle == 22.5.formatted(.percent.scale(1).precision(.fractionLength(0))))
        #expect(full.contextHelp.contains("200"))
        let noWindow = AgentStatus(model: nil, effort: nil, tokens: 45_000, window: nil, percent: 42)
        #expect(noWindow.contextTitle == 0.42.formatted(.percent.precision(.fractionLength(0))))
        #expect(noWindow.contextHelp.contains(noWindow.contextTitle), "the help names the percentage it has")
        let none = AgentStatus(model: nil, effort: nil, tokens: 45_000, window: 200_000, percent: nil)
        #expect(none.contextTitle == 45_000.formatted(.number.notation(.compactName)))
        #expect(!none.contextHelp.contains("%"))
    }
}
