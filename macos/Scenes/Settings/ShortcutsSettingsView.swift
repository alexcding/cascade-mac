import SwiftUI

/// Settings → Shortcuts: every command's key, grouped as the menu bar groups them, then each
/// agent's model presets. Sections for a grouped Form. A combination another command or macOS
/// holds is refused, never taken.
struct ShortcutsSettingsView: View {
    let registry: ShortcutRegistry
    /// Each agent's models; an agent whose models have not been read yet has no section.
    var catalogs: [SessionAgent: AgentCatalog] = [:]
    @State private var rejection: String?

    var body: some View {
        Section {
            SettingsRow(title: String(localized: "Keyboard shortcuts"),
                        caption: rejection ?? String(localized: "Click a shortcut, then press the new combination. Delete clears it.")) {
                Button("Restore Defaults") { registry.resetAll(); rejection = nil }
                    .disabled(!registry.hasCustom)
                    .accessibilityIdentifier("settings-shortcuts-reset")
            }
        }
        ForEach(ShortcutGroup.allCases) { group in
            Section(LocalizedStringKey(group.rawValue)) {
                ForEach(group.commands, id: \.self) { command in
                    SettingsRow(title: command.title) {
                        HStack(spacing: 6) {
                            if registry.isCustom(command) {
                                Button("Restore Default", systemImage: "arrow.uturn.backward") { rejection = registry.reset(command) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .help(command.defaultShortcut.map { String(localized: "Restore \($0.title)") } ?? String(localized: "Remove shortcut"))
                            }
                            ShortcutRecorder(shortcut: Binding(get: { registry.shortcut(for: command) },
                                                               set: { registry.assign($0, to: command) }),
                                             placeholder: String(localized: "None"),
                                             conflict: { registry.conflict($0, for: command) ?? presetConflict($0) },
                                             rejected: { rejection = $0 })
                        }
                    }
                }
            }
        }
        ForEach(SessionAgent.allCases.filter { catalogs[$0] != nil }) { agent in
            if let catalog = catalogs[agent], let driver = agent.driver {
                AgentPresetsSection(agent: agent, name: driver.name, catalog: catalog)
            }
        }
    }

    /// A command and a model preset on one key: only one of them would ever run.
    private func presetConflict(_ shortcut: KeyShortcut) -> String? {
        let store = AgentPresetStore()
        for agent in SessionAgent.allCases {
            guard let driver = agent.driver,
                  let preset = store.presets(for: agent).first(where: { $0.shortcut == shortcut }) else { continue }
            let model = catalogs[agent]?.model(preset.selection.model)?.name ?? preset.selection.model
            return String(localized: "\(shortcut.title) is already assigned to the \(driver.name) preset \(model).")
        }
        return nil
    }
}

/// One agent's model presets: the favourites Next Model (⌘D) steps through, each with a key of its
/// own if wanted. The same list as the model panel's ★ tab, so editing either changes both.
private struct AgentPresetsSection: View {
    let agent: SessionAgent
    let name: String
    let catalog: AgentCatalog
    @AppStorage private var list: AgentPresetList

    init(agent: SessionAgent, name: String, catalog: AgentCatalog) {
        self.agent = agent; self.name = name; self.catalog = catalog
        _list = AppStorage(wrappedValue: AgentPresetList(), AgentPresetList.key(for: agent.rawValue))
    }

    var body: some View {
        Section {
            AgentPresetEditor(catalog: catalog, presets: Binding(get: { list.resolved(in: catalog) }, set: { list.presets = $0 }))
        } header: {
            Text(String(localized: "\(name) Models"))
        } footer: {
            Text(String(localized: "Next Model steps through these in order. A preset’s own shortcut picks it. Over the terminal, hold the modifiers to keep choosing and let go to switch; in Chat the switch is immediate."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
