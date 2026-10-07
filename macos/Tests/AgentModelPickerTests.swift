import Foundation
import Testing
@testable import Cascade

// The model panel's rows and star rules, which follow Synara's picker.

private func catalog() -> AgentCatalog {
    var catalog = AgentCatalog()
    catalog.models = [
        .init(id: "claude-opus-5-5", alias: "opus", name: "Claude Opus 5.5",
              efforts: [.init(id: "low", name: "Low"), .init(id: "medium", name: "Medium"), .init(id: "high", name: "High")], defaultEffort: "medium"),
        .init(id: "claude-fable-5-1", alias: "fable", name: "Claude Fable 5.1",
              efforts: [.init(id: "medium", name: "Medium"), .init(id: "max", name: "Max")], defaultEffort: "medium"),
        .init(id: "claude-haiku-4-5", alias: "haiku", name: "Claude Haiku 4.5", efforts: [], defaultEffort: nil),
    ]
    return catalog
}

@Test func modelRowsFollowTheCatalogAndTheQuery() {
    let catalog = catalog()
    let running = AgentSelection(model: "opus", effort: "high")
    let all = AgentModelPanelRows.models(in: catalog, of: .claude, query: "", current: running)
    #expect(all.map(\.name) == ["Claude Opus 5.5", "Claude Fable 5.1", "Claude Haiku 4.5"])
    // The current model is the row, at whatever effort; the alias names it as the id does.
    #expect(all.map(\.selected) == [true, false, false])
    #expect(all.allSatisfy { $0.agent == .claude && !$0.isDefault })
    #expect(AgentModelPanelRows.models(in: catalog, of: .claude, query: " FABLE ", current: nil).map(\.model?.id) == ["claude-fable-5-1"])
    #expect(AgentModelPanelRows.models(in: catalog, of: .claude, query: "4-5", current: nil).map(\.model?.id) == ["claude-haiku-4-5"])
    #expect(AgentModelPanelRows.models(in: catalog, of: .claude, query: "gpt", current: nil).isEmpty)
}

@Test func aSessionNotStartedIsOfferedTheDefaultFirst() {
    let catalog = catalog()
    let rows = AgentModelPanelRows.models(in: catalog, of: .codex, query: "", current: nil, offersDefault: true)
    #expect(rows.first?.isDefault == true && rows.first?.selected == true && rows.first?.model == nil)
    #expect(rows.dropFirst().allSatisfy { !$0.selected && !$0.isDefault })
    let chosen = AgentModelPanelRows.models(in: catalog, of: .codex, query: "", current: .init(model: "haiku", effort: nil), offersDefault: true)
    #expect(chosen.map(\.selected) == [false, false, false, true])
    // A search is for models; the default is not one.
    #expect(AgentModelPanelRows.models(in: catalog, of: .codex, query: "d", current: nil, offersDefault: true).allSatisfy { !$0.isDefault })
}

@Test func starredRowsKeepTheirOrderAndAnUnavailablePreset() {
    let catalog = catalog()
    let presets = [
        AgentPreset(selection: .init(model: "claude-fable-5-1", effort: "max")),
        AgentPreset(selection: .init(model: "retired-model", effort: "low")),
        AgentPreset(selection: .init(model: "opus", effort: nil)),
    ]
    let rows = AgentModelPanelRows.starred(presets, of: .claude, in: catalog, query: "") { $0.model == "claude-fable-5-1" && $0.effort == "max" }
    #expect(rows.map(\.name) == ["Claude Fable 5.1", "retired-model", "Claude Opus 5.5"])
    #expect(rows.map(\.detail) == ["Max", "Unavailable", nil])
    #expect(rows.map(\.selected) == [true, false, false])
    #expect(rows[1].model == nil && rows[1].preset == presets[1], "a gone model stays, for its star to come off")
    #expect(AgentModelPanelRows.starred(presets, of: .claude, in: catalog, query: "retired") { _ in false }.map(\.name) == ["retired-model"])
    #expect(AgentModelPanelRows.starred(presets, of: .claude, in: catalog, query: "opus") { _ in false }.map(\.preset?.id) == [presets[2].id])
    // With no catalog read yet, nothing can run and nothing is said against the presets.
    let unread = AgentModelPanelRows.starred(presets, of: .claude, in: nil, query: "") { _ in true }
    #expect(unread.allSatisfy { $0.model == nil && $0.detail == nil && !$0.selected })
}

@Test func aModelRowCarriesTheCurrentEffortWhenTheModelHasIt() {
    let catalog = catalog()
    let opus = catalog.models[0], fable = catalog.models[1], haiku = catalog.models[2]
    #expect(AgentModelPanelRows.selection(of: fable, carrying: .init(model: "opus", effort: "medium")) == .init(model: "claude-fable-5-1", effort: "medium"))
    // A level the model lacks gives way to its default; no current model means the default too.
    #expect(AgentModelPanelRows.selection(of: fable, carrying: .init(model: "opus", effort: "high")) == .init(model: "claude-fable-5-1", effort: "medium"))
    #expect(AgentModelPanelRows.selection(of: opus, carrying: nil) == .init(model: "claude-opus-5-5", effort: "medium"))
    #expect(AgentModelPanelRows.selection(of: haiku, carrying: .init(model: "opus", effort: "high")) == .init(model: "claude-haiku-4-5", effort: nil))
}

@Test func starsToggleByModelAndEffortAndUnstarTakesEveryOneOfAModel() {
    let catalog = catalog()
    let opus = catalog.models[0]
    var presets: [AgentPreset] = []
    presets = AgentModelPanelRows.toggle(.init(model: "claude-opus-5-5", effort: "high"), in: presets, catalog: catalog)
    presets = AgentModelPanelRows.toggle(.init(model: "claude-opus-5-5", effort: "low"), in: presets, catalog: catalog)
    #expect(presets.map(\.selection.effort) == ["high", "low"])
    #expect(AgentModelPanelRows.isStarred(opus, in: presets, catalog: catalog))
    // The same model and effort, by alias, is the same star: toggling takes it off.
    presets = AgentModelPanelRows.toggle(.init(model: "opus", effort: "high"), in: presets, catalog: catalog)
    #expect(presets.map(\.selection.effort) == ["low"])
    presets = AgentModelPanelRows.toggle(.init(model: "claude-haiku-4-5", effort: nil), in: presets, catalog: catalog)
    presets = AgentModelPanelRows.unstar(opus, in: presets, catalog: catalog)
    #expect(presets.map(\.selection.model) == ["claude-haiku-4-5"])
    #expect(!AgentModelPanelRows.isStarred(opus, in: presets, catalog: catalog))
}

/// The panel stars into the same preference the session toolbar reads its presets from.
@Test func thePresetStoreIsTheToolbarsPreference() throws {
    let suite = "agent-preset-store-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AgentPresetStore(defaults: defaults)
    #expect(store.presets(for: .claude).isEmpty)
    let preset = AgentPreset(selection: .init(model: "claude-opus-5-5", effort: "high"), shortcut: KeyShortcut(key: "1", command: true))
    store.set([preset], for: .claude)
    #expect(store.presets(for: .claude) == [preset])
    #expect(store.presets(for: .codex).isEmpty)
    #expect(AgentPresetList(rawValue: try #require(defaults.string(forKey: AgentPresetList.key(for: "claude"))))?.presets == [preset])
}
