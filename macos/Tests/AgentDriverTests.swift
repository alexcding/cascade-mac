import Foundation
import SwiftUI
import Testing
@testable import Craft

@Suite struct AgentDriverTests {
    private let opus = AgentCatalog.Model(id: "claude-opus-5", alias: "opus", name: "Opus 5",
                                          efforts: [.init(id: "high", name: "High")], defaultEffort: "high")
    private static func levels(_ ids: [String]) -> [AgentCatalog.Effort] { ids.map { .init(id: $0, name: $0) } }
    private let astra = AgentCatalog.Model(id: "gpt-6-astra", alias: "gpt-6-astra", name: "GPT-6-Astra",
                                           efforts: levels(["low", "medium", "high", "xhigh", "max", "ultra"]), defaultEffort: "medium")
    private let older = AgentCatalog.Model(id: "gpt-5.5", alias: "gpt-5.5", name: "GPT-5.5",
                                           efforts: levels(["low", "medium", "high", "xhigh"]), defaultEffort: "medium")

    @Test func claudeSwitchesAtItsPromptByAlias() throws {
        let driver = AgentDrivers.driver(for: nil)
        let catalog = AgentCatalog(models: [opus])
        #expect(driver.cli == "claude")
        #expect(try driver.switchInputs(to: opus, effort: "high", in: catalog) == [.line("/model opus"), .line("/effort high")])
        #expect(try driver.switchInputs(to: opus, effort: nil, in: catalog) == [.line("/model opus")])
    }

    @Test func claudeLaunchCarriesTheStatusLineWithoutTouchingUserSettings() throws {
        let line = AgentStatusLine(script: "/Apps/Craft Dev.app/it's.sh", taskID: "task-1")
        let command = ClaudeDriver().launchCommand(sessionID: "new", fresh: true, selection: nil, effort: nil, statusLine: line)
        #expect(command.hasPrefix("claude --session-id 'new' --settings '"))
        // Undo the shell quoting: what Claude receives must be the JSON naming the wrapper and task.
        let quoted = String(command.dropFirst("claude --session-id 'new' --settings ".count))
        let json = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        let value = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: String]])
        #expect(value["statusLine"]?["type"] == "command")
        #expect(value["statusLine"]?["command"] == "/bin/sh '/Apps/Craft Dev.app/it'\"'\"'s.sh' 'task-1'")
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
}
