import AppKit
import SwiftUI

/// One entry in the model menu: a model and effort, and the shortcut that reaches it.
struct AgentPreset: Codable, Equatable, Identifiable, Sendable {
    /// Random for a preset the user adds; derived from the model for one the catalog stands in
    /// with, so the same stand-in is the same row from one render to the next.
    var id = UUID().uuidString
    var selection: AgentSelection
    var shortcut: AgentShortcut?
}

/// The presets the model menu lists, stored per CLI so each keeps its own models.
struct AgentPresetList: RawRepresentable, Equatable {
    var presets: [AgentPreset] = []

    /// The preference a CLI's presets are kept under, read wherever the panel opens (`AgentPresetStore`).
    static func key(for cli: String) -> String { "workspace.agentPresetList.\(cli)" }

    init() {}
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let value = try? JSONDecoder().decode([AgentPreset].self, from: data) else { return nil }
        presets = value
    }
    /// Sorted keys, because two of these are compared by this string: the standard library's `==`
    /// for a `RawRepresentable` wins over the synthesized one, and JSON key order is otherwise
    /// free to differ between two encodings of the same presets.
    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(presets)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The stored presets whose models the catalog still lists: a CLI's models change, and a
    /// preset naming a gone one cannot run. With none left, the catalog's first two at their
    /// default efforts, so the menu is never empty.
    func resolved(in catalog: AgentCatalog) -> [AgentPreset] {
        let listed = presets.filter { catalog.model($0.selection.model) != nil }
        if !listed.isEmpty { return listed }
        return catalog.models.prefix(2).map {
            AgentPreset(id: "default-\($0.id)", selection: AgentSelection(model: $0.id, effort: $0.defaultEffort))
        }
    }
}

/// What a session's agent needs while its workspace is shown, with nothing to see: its presets,
/// and the status the Chat composer and the model panel read. The toolbar shows only
/// Terminal / Chat; the model and the context are the agent's own to show, in its status line
/// in the terminal and in the composer in Chat. It holds a driver and a catalog, and never asks
/// which CLI they belong to.
struct SessionAgentKeeper: View {
    let model: SessionWorkspaceViewModel
    @AppStorage private var list: AgentPresetList

    init(model: SessionWorkspaceViewModel, driver: any AgentDriver) {
        self.model = model
        _list = AppStorage(wrappedValue: AgentPresetList(), AgentPresetList.key(for: driver.cli))
    }

    private var presets: [AgentPreset] { list.resolved(in: model.agentCatalog) }

    /// Hands the presets to the model, whose shortcuts the app takes ahead of the terminal
    /// (`AppViewModel.choosePreset(for:)`), and watches the agent's status.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: model.agentStatusTrigger) { await model.watchAgentStatus() }
            .onChange(of: presets, initial: true) { model.agentPresets = presets }
    }
}

/// The presets as a table: model, effort, shortcut; reached from the model panel's ★ tab.
struct AgentPresetEditor: View {
    let catalog: AgentCatalog
    @Binding var presets: [AgentPreset]
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presets) { preset in
                let efforts = catalog.model(preset.selection.model)?.efforts ?? []
                HStack(spacing: 8) {
                    Picker(String(localized: "Model"), selection: Binding(get: { catalog.model(preset.selection.model)?.id ?? preset.selection.model },
                                                       set: { select($0, for: preset.id) })) {
                        ForEach(catalog.models) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 150)
                    Picker(String(localized: "Effort"), selection: Binding(get: { preset.selection.effort ?? "" },
                                                        set: { effort in change(preset.id) { $0.selection.effort = effort.isEmpty ? nil : effort } })) {
                        // No level at all is the CLI's own default.
                        if !efforts.isEmpty { Text(String(localized: "Default")).tag("") }
                        ForEach(efforts) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 110)
                    .disabled(efforts.isEmpty)
                    ShortcutRecorder(shortcut: Binding(get: { preset.shortcut }, set: { value in assign(value, to: preset.id) }),
                                     conflict: { ShortcutRegistry.shared.conflict($0) }, rejected: { rejection = $0 })
                    Button(String(localized: "Remove Preset"), systemImage: "minus.circle") { presets.removeAll { $0.id == preset.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(presets.count == 1)
                }
                .labelsHidden()
            }
            Button(String(localized: "Add Preset"), systemImage: "plus") {
                guard let first = catalog.models.first else { return }
                presets.append(AgentPreset(selection: AgentSelection(model: first.id, effort: first.defaultEffort)))
            }
            .disabled(catalog.models.isEmpty)
            Text(rejection ?? String(localized: "A shortcut needs ⌘, so it never takes a key from the CLI. It works while this window is in front; one a menu command holds is refused."))
                .font(.caption).foregroundStyle(rejection == nil ? Theme.textSecondary : Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440)
    }

    private func change(_ id: String, _ edit: (inout AgentPreset) -> Void) {
        var value = presets
        guard let index = value.firstIndex(where: { $0.id == id }) else { return }
        edit(&value[index])
        presets = value
    }

    /// A model brings its own effort levels, so the effort follows when the old one is not among them.
    private func select(_ model: String, for id: String) {
        guard let chosen = catalog.model(model) else { return }
        change(id) { preset in
            preset.selection.model = chosen.id
            if !chosen.efforts.contains(where: { $0.id == preset.selection.effort }) {
                preset.selection.effort = chosen.defaultEffort
            }
        }
    }

    /// One shortcut, one preset: giving it to this one takes it from whichever had it.
    private func assign(_ shortcut: AgentShortcut?, to id: String) {
        var value = presets
        for index in value.indices where value[index].id != id && shortcut != nil && value[index].shortcut == shortcut {
            value[index].shortcut = nil
        }
        if let index = value.firstIndex(where: { $0.id == id }) { value[index].shortcut = shortcut }
        presets = value
    }
}
