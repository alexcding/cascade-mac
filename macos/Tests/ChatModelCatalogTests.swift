import Foundation
import Testing
@testable import Cascade

/// The app lists a chat's models as the chat page does: Synara's catalogue merged with what the
/// CLI reported, by Synara's own code. The expectations are the page's own answers for this input.
@Test func theCatalogueListsModelsAsThePageDoes() async throws {
    // The script built beside the page in the source tree, which the test bundle does not carry.
    let catalog = ChatModelCatalog(script: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ChatPage/ChatModelCatalog.js"))
    let reported: [ChatModelOption] = [
        ("Opus 5.5", "claude-opus-5-5"), ("Fable 5.1", "claude-fable-5-1"), ("Sonnet 5.5", "claude-sonnet-5-5"),
        ("Haiku 4.5", "claude-haiku-4-5-20251001"), ("Sonnet 5", "claude-sonnet-5"), ("Opus 5", "claude-opus-5"),
        ("Fable 5", "claude-fable-5"), ("Opus 4.8", "claude-opus-4-8"), ("Opus 4.7", "claude-opus-4-7"),
        ("Opus 4.6", "claude-opus-4-6"), ("Sonnet 4.6", "claude-sonnet-4-6"), ("Default (recommended)", "default"),
    ].map { ChatModelOption(slug: $0.1, name: $0.0) }
    let listed = try #require(await catalog.list(provider: "claudeAgent", runtime: reported))
    // The catalogue's order and names; the CLI's "default" alias is not a model; a dated id is
    // the model it names; a model the CLI did not report but the catalogue knows is listed too.
    #expect(listed.map(\.slug) == ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
                                   "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-sonnet-5-5", "claude-sonnet-5",
                                   "claude-sonnet-4-6", "claude-haiku-4-5"])
    #expect(listed.map(\.title) == ["Claude Fable 5.1", "Claude Fable 5", "Claude Opus 5.5", "Claude Opus 5", "Claude Opus 4.8",
                                    "Claude Opus 4.7", "Claude Opus 4.6", "Claude Opus 4.5", "Claude Sonnet 5.5", "Claude Sonnet 5",
                                    "Claude Sonnet 4.6", "Claude Haiku 4.5"])
    #expect(listed.filter { $0.isDefault == true }.map(\.slug) == ["claude-sonnet-5"], "Synara's default for Claude")
    // Codex's own list is the list; the catalogue lends the name.
    let codex = try #require(await catalog.list(provider: "codex", runtime: [ChatModelOption(slug: "gpt-6-astra", name: "gpt-6-astra")]))
    #expect(codex.map(\.slug) == ["gpt-6-astra"] && codex.map(\.title) == ["GPT-6 Astra"] && codex.first?.isDefault == true)
}

/// The traits the footer draws, and what its controls commit, are the page's own: here for the
/// CLI's Opus 5.5 descriptor, with the catalogue's capabilities behind it.
@Test func theCatalogueResolvesTraitsAndOptionChangesAsThePageDoes() async throws {
    let catalog = ChatModelCatalog(script: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ChatPage/ChatModelCatalog.js"))
    var opus = ChatModelOption(slug: "claude-opus-5-5", name: "Opus 5.5")
    opus.descriptor = ["slug": "claude-opus-5-5", "name": "Opus 5.5",
                       "supportedReasoningEfforts": [["label": "Low", "value": "low"], ["label": "Medium", "value": "medium"], ["label": "High", "value": "high"],
                                                     ["label": "Extra", "value": "xhigh"], ["label": "Max", "value": "max"]]]
    let haiku = ChatModelOption(slug: "claude-haiku-4-5-20251001", name: "Haiku 4.5")
    let runtime = [opus, haiku]

    let fresh = try #require(await catalog.traits(provider: "claudeAgent", model: "claude-opus-5-5", runtime: runtime, options: [:]))
    #expect(fresh.effortLevels.map(\.label) == ["Low", "Medium", "High", "Extra High", "Max", "Ultracode"])
    #expect(fresh.effort == "high" && fresh.defaultEffort == "high" && fresh.ladderIndex == 2 && fresh.statusLabel == "High")
    #expect(fresh.supportsFastMode && !fresh.fastModeEnabled && fresh.thinkingEnabled == nil && !fresh.locked)
    #expect(fresh.contextLabel == "Auto-compact" && fresh.contextId == "autoCompactWindow" && fresh.contextWindow == "auto")
    #expect(fresh.contextOptions.map(\.label) == ["Auto (Claude Code)", "200k", "1M"])

    let atMax = try #require(await catalog.setEffort(provider: "claudeAgent", model: "claude-opus-5-5", runtime: runtime, options: [:], value: "max"))
    #expect(atMax == ["effort": "max"])
    let fast = try #require(await catalog.setTrait(provider: "claudeAgent", options: atMax, patch: ["fastMode": true]))
    #expect(fast == ["effort": "max", "fastMode": true])
    let after = try #require(await catalog.traits(provider: "claudeAgent", model: "claude-opus-5-5", runtime: runtime, options: fast))
    #expect(after.effort == "max" && after.ladderIndex == 4 && after.statusLabel == "Max" && after.fastModeEnabled)
    let reset = try #require(await catalog.resetTraits(provider: "claudeAgent", model: "claude-opus-5-5", runtime: runtime, options: fast))
    #expect(reset == ["effort": "high", "fastMode": false])
    // A level the page sets through the prompt is not one these forms can set.
    #expect(await catalog.setEffort(provider: "claudeAgent", model: "claude-opus-5-5", runtime: runtime, options: [:], value: "ultrathink") == nil)

    // Haiku has no ladder, a thinking switch instead.
    let small = try #require(await catalog.traits(provider: "claudeAgent", model: "claude-haiku-4-5", runtime: runtime, options: [:]))
    #expect(small.effortLevels.isEmpty && small.thinkingEnabled == true && small.statusLabel == "Thinking On" && !small.supportsFastMode)
}

/// Every listed model's ladder in one answer, for the form to know which can be tuned.
@Test func theCatalogueAnswersEveryListedModelsLadder() async throws {
    let catalog = ChatModelCatalog(script: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ChatPage/ChatModelCatalog.js"))
    var opus = ChatModelOption(slug: "claude-opus-5-5", name: "Opus 5.5")
    opus.descriptor = ["slug": "claude-opus-5-5", "name": "Opus 5.5",
                       "supportedReasoningEfforts": [["label": "Low", "value": "low"], ["label": "High", "value": "high"]]]
    let ladders = try #require(await catalog.ladders(provider: "claudeAgent", runtime: [opus, ChatModelOption(slug: "claude-haiku-4-5-20251001", name: "Haiku 4.5")]))
    let opusLadder = try #require(ladders["claude-opus-5-5"])
    #expect(opusLadder.levels.first?.value == "low" && opusLadder.levels.contains { $0.value == "high" } && opusLadder.defaultEffort == "high")
    #expect(ladders["claude-haiku-4-5"]?.levels.isEmpty == true)
    #expect(ladders["claude-fable-5-1"] != nil, "a catalogue model the CLI did not report is listed, with its ladder")
}
