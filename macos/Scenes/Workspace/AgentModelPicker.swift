import SwiftUI

/// One row of the model panel, resolved to what picking it does: Synara's `ComposerModelPickerRow`
/// (`macos/web/chat/vendor/synara/apps/web/src/components/chat/ComposerModelPicker.logic.ts`).
struct AgentModelRow: Identifiable, Equatable {
    let id: String
    let agent: SessionAgent
    /// The catalog's model; nil for the CLI's own default, or for a preset naming a model the CLI
    /// no longer lists (unavailable).
    let model: AgentCatalog.Model?
    let name: String
    /// Muted text after the name: the effort a preset pins, or why it cannot run.
    let detail: String?
    let selected: Bool
    /// The preset a ★ row restores and un-stars; nil on a model row.
    let preset: AgentPreset?
    /// The CLI's own default, named by no model: a session not started yet may leave it the choice.
    var isDefault = false
}

/// The panel's rows and its star rules, as Synara's picker has them (`buildProviderTabRows`,
/// `buildStarredTabRows`, `toggleStarredModel`, `unstarModel`), on the app's presets: a star is a
/// preset, one model at the effort it was starred at.
enum AgentModelPanelRows {
    /// An agent's tab: its catalog in its order, narrowed by `query` on name and ids, after the
    /// CLI's default when that is on offer. The model `current` names is selected, whatever its
    /// effort; the default is, when nothing is chosen.
    static func models(in catalog: AgentCatalog, of agent: SessionAgent, query: String, current: AgentSelection?,
                       offersDefault: Bool = false) -> [AgentModelRow] {
        let query = normalized(query)
        let currentModel = current.flatMap { catalog.model($0.model)?.id }
        var rows: [AgentModelRow] = []
        if offersDefault, query.isEmpty {
            rows.append(AgentModelRow(id: "\(agent.rawValue):default", agent: agent, model: nil, name: String(localized: "Default"),
                                      detail: nil, selected: current == nil, preset: nil, isDefault: true))
        }
        rows += catalog.models
            .filter { query.isEmpty || [$0.name, $0.id, $0.alias].joined(separator: " ").lowercased().contains(query) }
            .map { AgentModelRow(id: "\(agent.rawValue):\($0.id)", agent: agent, model: $0, name: $0.name, detail: nil,
                                 selected: $0.id == currentModel, preset: nil) }
        return rows
    }

    /// The ★ tab's rows for one agent: its presets in their order, narrowed by `query`. One
    /// naming a model the CLI no longer lists stays, unavailable, so its star can be taken off;
    /// with no catalog read yet, none can run. `isCurrent` tells the one the agent is on.
    static func starred(_ presets: [AgentPreset], of agent: SessionAgent, in catalog: AgentCatalog?, query: String,
                        isCurrent: (AgentSelection) -> Bool) -> [AgentModelRow] {
        let query = normalized(query)
        return presets.compactMap { preset in
            let model = catalog?.model(preset.selection.model)
            let name = model?.name ?? preset.selection.model
            guard query.isEmpty || "\(name) \(preset.selection.model)".lowercased().contains(query) else { return nil }
            let effort = model.flatMap { listed in listed.efforts.first { $0.id == preset.selection.effort }?.name } ?? preset.selection.effort
            let detail: String? = catalog == nil ? nil : model == nil ? String(localized: "Unavailable") : effort
            return AgentModelRow(id: "\(agent.rawValue):preset:\(preset.id)", agent: agent, model: model, name: name, detail: detail,
                                 selected: model != nil && isCurrent(preset.selection), preset: preset)
        }
    }

    /// What a model row switches to or stars: the model at the effort `current` runs at when the
    /// model has that level, else at its own default; at none for a model with no levels.
    static func selection(of model: AgentCatalog.Model, carrying current: AgentSelection?) -> AgentSelection {
        guard !model.efforts.isEmpty else { return AgentSelection(model: model.id, effort: nil) }
        let carried = current?.effort.flatMap { level in model.efforts.contains { $0.id == level } ? level : nil }
        return AgentSelection(model: model.id, effort: carried ?? model.defaultEffort)
    }

    /// Whether a preset is `model`'s, at whatever effort: the model row's star.
    static func isStarred(_ model: AgentCatalog.Model, in presets: [AgentPreset], catalog: AgentCatalog) -> Bool {
        presets.contains { catalog.model($0.selection.model)?.id == model.id }
    }

    /// Stars `selection`, or takes its star off when it is starred as it is.
    static func toggle(_ selection: AgentSelection, in presets: [AgentPreset], catalog: AgentCatalog) -> [AgentPreset] {
        func same(_ preset: AgentPreset) -> Bool {
            (catalog.model(preset.selection.model)?.id ?? preset.selection.model) == (catalog.model(selection.model)?.id ?? selection.model)
                && preset.selection.effort == selection.effort
        }
        if presets.contains(where: same) { return presets.filter { !same($0) } }
        return presets + [AgentPreset(selection: selection)]
    }

    /// Takes off every star of `model`, whatever effort each pins.
    static func unstar(_ model: AgentCatalog.Model, in presets: [AgentPreset], catalog: AgentCatalog) -> [AgentPreset] {
        presets.filter { catalog.model($0.selection.model)?.id != model.id }
    }

    private static func normalized(_ query: String) -> String { query.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// The presets of each CLI, where the session toolbar keeps them (`AgentPresetList`), for the
/// panel to read and star into wherever it opens.
struct AgentPresetStore {
    var defaults = UserDefaults.standard

    func presets(for agent: SessionAgent) -> [AgentPreset] {
        defaults.string(forKey: AgentPresetList.key(for: agent.rawValue)).flatMap(AgentPresetList.init(rawValue:))?.presets ?? []
    }

    func set(_ presets: [AgentPreset], for agent: SessionAgent) {
        var list = AgentPresetList()
        list.presets = presets
        defaults.set(list.rawValue, forKey: AgentPresetList.key(for: agent.rawValue))
    }
}

/// The current model's traits the panel's footer draws, as the chat page's does
/// (`ComposerModelPickerTraitRows`): the effort ladder and where it stands, speed, thinking, and
/// the context window. A chat's come from the page's own resolution (`ChatModelTraits`); a
/// terminal agent's from its CLI's catalog, which reports a ladder and nothing else.
struct AgentModelTraits: Equatable {
    struct Level: Equatable, Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }
    struct Context: Equatable {
        let label: String
        let options: [Level]
        let value: String?
        let defaultValue: String?
    }
    var effortLevels: [Level] = []
    var effort: String?
    var defaultEffort: String?
    var ladderIndex = 0
    var statusLabel: String?
    /// Ultrathink in the prompt pins the ladder.
    var locked = false
    var supportsFastMode = false
    var fastModeEnabled = false
    var thinking: Bool?
    var context: Context?

    init(_ traits: ChatModelTraits) {
        effortLevels = traits.effortLevels.map { Level(value: $0.value, label: $0.label) }
        effort = traits.effort
        defaultEffort = traits.defaultEffort
        ladderIndex = traits.ladderIndex
        statusLabel = traits.statusLabel
        locked = traits.locked
        supportsFastMode = traits.supportsFastMode
        fastModeEnabled = traits.fastModeEnabled
        thinking = traits.thinkingEnabled
        if traits.contextOptions.count > 1 {
            context = Context(label: traits.contextLabel ?? String(localized: "Context"),
                              options: traits.contextOptions.map { Level(value: $0.value, label: $0.label) },
                              value: traits.contextWindow, defaultValue: traits.defaultContextWindow)
        }
    }

    /// A CLI's `model` at `effort`; none is the model's own default level.
    init(model: AgentCatalog.Model, effort: String?) {
        effortLevels = model.efforts.map { Level(value: $0.id, label: $0.name) }
        defaultEffort = model.defaultEffort
        self.effort = effort ?? model.defaultEffort
        ladderIndex = effortLevels.firstIndex { $0.value == self.effort } ?? 0
        statusLabel = effortLevels.first { $0.value == self.effort }?.label
    }

    /// Whether there is anything to draw.
    var isEmpty: Bool { effortLevels.isEmpty && thinking == nil && context == nil }
}

/// The model panel: Synara's composer picker, native, wherever a model is picked. Tabs, ★ for the
/// presets then one per agent, a search field, rows a click picks, and under them the current
/// model's traits as the page's footer draws them: the effort slider with speed and reset, then
/// thinking and the context window. A star pins a model at the effort it is at. As on the page,
/// a model picked stays open for its effort; a preset carries its own, and picking the current
/// model again closes. Opens on the presets when there are any. In a session's toolbar the one
/// agent's running model is marked and the presets' shortcuts are edited from the ★ tab; starting
/// a session, every agent has a tab, a tab click picks that agent, and the CLI's own default is on
/// offer.
struct AgentModelPanel: View {
    /// One agent's tab: its catalog, nil until read, whether it is being read, and why it cannot
    /// be picked, when it cannot (not installed, not signed in).
    struct Agent: Identifiable, Equatable {
        let agent: SessionAgent
        var catalog: AgentCatalog?
        var loading = false
        var unavailable: String?
        var id: String { agent.rawValue }
    }

    let agents: [Agent]
    /// The agent whose model is marked, and that model; nil for the CLI's own default.
    let currentAgent: SessionAgent
    let current: AgentSelection?
    let canChoose: Bool
    /// Offers the CLI's own default as a row: a session not started yet may keep it.
    let offersDefault: Bool
    /// Edits the presets' shortcuts from the ★ tab: in a session's toolbar, where they switch it.
    let editsShortcuts: Bool
    let isCurrent: (SessionAgent, AgentSelection) -> Bool
    let chooseAgent: (SessionAgent) -> Void
    /// A pick: the agent and its model and effort, or nil for the CLI's own default.
    let choose: (SessionAgent, AgentSelection?) -> Void
    let dismiss: () -> Void
    /// The current model's traits, and what each of the footer's controls commits.
    let traits: AgentModelTraits?
    let onEffort: (String) -> Void
    let onFastMode: (Bool) -> Void
    let onThinking: (Bool) -> Void
    let onContext: (String) -> Void
    let onReset: () -> Void
    private let store: AgentPresetStore

    private enum Tab: Hashable { case starred, agent(SessionAgent) }
    @State private var tab: Tab
    @State private var query = ""
    /// The row the keyboard is on, from the search field's arrows.
    @State private var highlighted: String?
    @State private var editingShortcuts = false
    @State private var presets: [SessionAgent: [AgentPreset]]
    @FocusState private var searching: Bool

    init(agents: [Agent], currentAgent: SessionAgent, current: AgentSelection?, canChoose: Bool, offersDefault: Bool, editsShortcuts: Bool,
         isCurrent: @escaping (SessionAgent, AgentSelection) -> Bool, chooseAgent: @escaping (SessionAgent) -> Void,
         choose: @escaping (SessionAgent, AgentSelection?) -> Void, dismiss: @escaping () -> Void,
         traits: AgentModelTraits? = nil, onEffort: @escaping (String) -> Void = { _ in }, onFastMode: @escaping (Bool) -> Void = { _ in },
         onThinking: @escaping (Bool) -> Void = { _ in }, onContext: @escaping (String) -> Void = { _ in }, onReset: @escaping () -> Void = {},
         store: AgentPresetStore = AgentPresetStore()) {
        self.agents = agents; self.currentAgent = currentAgent; self.current = current; self.canChoose = canChoose
        self.offersDefault = offersDefault; self.editsShortcuts = editsShortcuts
        self.isCurrent = isCurrent; self.chooseAgent = chooseAgent; self.choose = choose; self.dismiss = dismiss
        self.traits = traits; self.onEffort = onEffort; self.onFastMode = onFastMode; self.onThinking = onThinking
        self.onContext = onContext; self.onReset = onReset
        self.store = store
        let presets = Dictionary(uniqueKeysWithValues: agents.map { ($0.agent, store.presets(for: $0.agent)) })
        _presets = State(initialValue: presets)
        _tab = State(initialValue: presets.values.contains { !$0.isEmpty } ? .starred : .agent(currentAgent))
    }

    var body: some View {
        if editingShortcuts, let entry = agents.first(where: { $0.agent == currentAgent }) {
            VStack(alignment: .trailing, spacing: 0) {
                // The editor drops a preset naming a model the CLI no longer lists, as it cannot run.
                AgentPresetEditor(catalog: entry.catalog ?? AgentCatalog(),
                                  presets: Binding(get: { (presets[entry.agent] ?? []).filter { entry.catalog?.model($0.selection.model) != nil } },
                                                   set: { set($0, for: entry.agent) }))
                Button(String(localized: "Done")) { editingShortcuts = false }
                    .keyboardShortcut(.defaultAction)
                    .padding([.horizontal, .bottom], 14)
            }
        } else {
            VStack(spacing: 0) {
                tabs
                hairline
                search
                hairline
                list
                if hasFooter {
                    hairline
                    footer
                }
            }
            .frame(width: 300)
            .foregroundStyle(Theme.chatPanelText)
            .onAppear { searching = true }
            .accessibilityIdentifier("agent-model-panel")
        }
    }

    // MARK: Rows

    private var shownAgent: Agent? {
        guard case .agent(let agent) = tab else { return nil }
        return agents.first { $0.agent == agent }
    }

    private var rows: [AgentModelRow] {
        switch tab {
        case .starred:
            agents.flatMap { entry in
                AgentModelPanelRows.starred(presets[entry.agent] ?? [], of: entry.agent, in: entry.catalog, query: query) { isCurrent(entry.agent, $0) }
            }
        case .agent(let agent):
            if let catalog = shownAgent?.catalog {
                AgentModelPanelRows.models(in: catalog, of: agent, query: query, current: agent == currentAgent ? current : nil,
                                           offersDefault: offersDefault)
            } else {
                []
            }
        }
    }

    private func catalog(of agent: SessionAgent) -> AgentCatalog { agents.first { $0.agent == agent }?.catalog ?? AgentCatalog() }

    private func set(_ value: [AgentPreset], for agent: SessionAgent) {
        presets[agent] = value
        store.set(value, for: agent)
    }

    private func isStarred(_ row: AgentModelRow) -> Bool {
        row.preset != nil || row.model.map { AgentModelPanelRows.isStarred($0, in: presets[row.agent] ?? [], catalog: catalog(of: row.agent)) } ?? false
    }

    /// The effort a model row would run at; a ★ row pins its own.
    private func carried(_ row: AgentModelRow) -> AgentSelection? {
        guard row.preset == nil, let model = row.model else { return nil }
        return AgentModelPanelRows.selection(of: model, carrying: row.agent == currentAgent ? current : nil)
    }

    private func pick(_ row: AgentModelRow) {
        guard canChoose, row.model != nil || row.isDefault else { return }
        // A model picked stays open for its effort, as the page's slider mode does: a preset
        // carries its own, picking the current model again is the "done" gesture, and a model
        // with no ladder to tune closes too.
        let keepOpen = row.preset == nil && !row.selected && !row.isDefault && !(row.model?.efforts.isEmpty ?? true)
        if row.isDefault { choose(row.agent, nil) } else if let preset = row.preset { choose(row.agent, preset.selection) } else if let selection = carried(row) { choose(row.agent, selection) }
        if !keepOpen { dismiss() }
    }

    /// A ★ row's star takes that preset off. A model row's stars the model at the effort it would
    /// run at, or, starred at any effort already, takes every star of it off.
    private func toggleStar(_ row: AgentModelRow) {
        let catalog = catalog(of: row.agent), current = presets[row.agent] ?? []
        if let preset = row.preset {
            set(AgentModelPanelRows.toggle(preset.selection, in: current, catalog: catalog), for: row.agent)
        } else if let model = row.model {
            set(isStarred(row)
                ? AgentModelPanelRows.unstar(model, in: current, catalog: catalog)
                : AgentModelPanelRows.toggle(AgentModelPanelRows.selection(of: model, carrying: carried(row)), in: current, catalog: catalog),
                for: row.agent)
        }
    }

    /// Tab walks the tabs, as on the page, instead of leaving the search field.
    private func cycleTab(_ delta: Int) {
        let tabs: [Tab] = [.starred] + agents.filter { $0.unavailable == nil }.map { .agent($0.agent) }
        guard let index = tabs.firstIndex(of: tab) else { return }
        let next = tabs[(index + delta + tabs.count) % tabs.count]
        tab = next; query = ""; highlighted = nil; searching = true
        if case .agent(let agent) = next { chooseAgent(agent) }
    }

    private func move(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted }.map { ($0 + delta + rows.count) % rows.count } ?? (delta > 0 ? 0 : rows.count - 1)
        highlighted = rows[index].id
    }

    // MARK: Parts

    private var hairline: some View { Rectangle().fill(Theme.chatPanelBorder).frame(height: 1) }

    private var tabs: some View {
        HStack(spacing: 2) {
            tabButton(.starred, help: String(localized: "Starred")) {
                Image(systemName: "star.fill").font(.system(size: 13, weight: .semibold))
            }
            ForEach(agents) { entry in
                tabButton(.agent(entry.agent), help: entry.unavailable ?? entry.agent.label) { StartAgentMark(agent: entry.agent) }
                    .disabled(entry.unavailable != nil)
                    .opacity(entry.unavailable == nil ? 1 : 0.5)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func tabButton<Label: View>(_ value: Tab, help: String, @ViewBuilder label: @escaping () -> Label) -> some View {
        AgentPanelTab(selected: tab == value, help: help) {
            tab = value; query = ""; highlighted = nil; searching = true
            if case .agent(let agent) = value { chooseAgent(agent) }
        } label: { label() }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.chatPanelMuted.opacity(0.55))
            TextField(text: $query, prompt: Text(tab == .starred ? String(localized: "Search starred…") : String(localized: "Search models…"))
                        .foregroundStyle(Theme.chatPanelMuted.opacity(0.55))) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onChange(of: query) { highlighted = nil }
                // Return takes the row the arrows are on, or the top hit.
                .onSubmit { if let row = rows.first(where: { $0.id == highlighted }) ?? rows.first { pick(row) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.tab, phases: .down) { press in cycleTab(press.modifiers.contains(.shift) ? -1 : 1); return .handled }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// As tall as its rows, up to a cap; past it, it scrolls.
    private var list: some View {
        ViewThatFits(in: .vertical) {
            listRows
            ScrollView { listRows }
        }
        .frame(maxHeight: 220)
    }

    private var listRows: some View {
        VStack(spacing: 1) {
            if let note = note {
                Text(note)
                    .font(.system(size: 12)).foregroundStyle(Theme.chatPanelMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 12)
            } else {
                ForEach(rows) { row in
                    AgentModelRowView(row: row, mark: tab == .starred && agents.count > 1, starred: isStarred(row),
                                      highlighted: highlighted == row.id, enabled: canChoose, shortcut: row.preset?.shortcut?.title,
                                      pick: { pick(row) }, toggleStar: { toggleStar(row) })
                }
            }
        }
        .padding(4)
        .frame(minHeight: 80)
    }

    /// What the list says instead of rows: a tab with nothing to list, or a search with no hit.
    private var note: String? {
        if let shown = shownAgent, shown.catalog == nil {
            if let unavailable = shown.unavailable { return unavailable }
            if shown.agent == .shell { return String(localized: "A shell has no model to choose.") }
            return shown.loading ? String(localized: "Loading models…")
                                 : String(localized: "No models to choose from: the agent starts on its default.")
        }
        guard rows.isEmpty else { return nil }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "No matches") }
        return tab == .starred
            ? String(localized: "Star a model to pin it here together with its effort, then pick it in one click.")
            : String(localized: "No models found")
    }

    private var hasFooter: Bool { !(traits?.isEmpty ?? true) || (editsShortcuts && tab == .starred) }

    /// The current model's traits, as the page's footer: the effort slider card, then a row each
    /// for thinking and the context window, with a menu; and the way to the presets' shortcuts.
    private var footer: some View {
        VStack(spacing: 1) {
            if let traits {
                if !traits.effortLevels.isEmpty {
                    AgentEffortSliderCard(traits: traits, enabled: canChoose, onEffort: onEffort, onFastMode: onFastMode, onReset: onReset)
                }
                if let thinking = traits.thinking {
                    menuRow(String(localized: "Thinking"), value: thinking ? "on" : "off", defaultValue: "on",
                            options: [.init(value: "on", label: String(localized: "On")), .init(value: "off", label: String(localized: "Off"))]) {
                        onThinking($0 == "on")
                    }
                }
                if let context = traits.context {
                    menuRow(context.label, value: context.value ?? context.defaultValue ?? "", defaultValue: context.defaultValue,
                            options: context.options, choose: onContext)
                }
            }
            if editsShortcuts, tab == .starred {
                Button { editingShortcuts = true } label: {
                    AgentPanelFooterRow(title: String(localized: "Shortcuts…"), value: nil, opens: false)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Give the presets keyboard shortcuts"))
            }
        }
        .padding(4)
    }

    /// A trait row: what it is set to, and a menu of what it can be, the default said.
    private func menuRow(_ title: String, value: String, defaultValue: String?, options: [AgentModelTraits.Level],
                         choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options) { option in
                Toggle(option.value == defaultValue ? String(localized: "\(option.label) (default)") : option.label,
                       isOn: Binding(get: { value == option.value }, set: { _ in choose(option.value) }))
            }
        } label: {
            AgentPanelFooterRow(title: title, value: options.first { $0.value == value }?.label ?? value, opens: true)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!canChoose)
    }
}

/// A row: its agent's mark where presets of several agents mix, the name, a preset's effort beside
/// it, the preset's shortcut, and its star. The current one is marked.
private struct AgentModelRowView: View {
    let row: AgentModelRow
    let mark: Bool
    let starred: Bool
    let highlighted: Bool
    let enabled: Bool
    let shortcut: String?
    let pick: () -> Void
    let toggleStar: () -> Void
    @State private var hovering = false

    private var available: Bool { row.model != nil || row.isDefault }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pick) {
                HStack(spacing: 6) {
                    if mark { StartAgentMark(agent: row.agent) }
                    Text(row.name).lineLimit(1)
                    if let detail = row.detail {
                        Text(detail).foregroundStyle(Theme.chatPanelMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || !available)
            if let shortcut { shortcutBadge(shortcut) }
            if !row.isDefault { starButton }
        }
        .font(.system(size: 12.5))
        .opacity(available ? 1 : 0.64)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(highlighted || hovering ? Theme.chatPanelHover : row.selected ? Theme.chatPanelSelected : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-model-row")
        .accessibilityAddTraits(row.selected ? .isSelected : [])
    }

    private func shortcutBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.chatPanelMuted)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.chatPanelHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var starButton: some View {
        Button(action: toggleStar) {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(starred ? Theme.chatPanelStar : Theme.chatPanelMuted.opacity(0.5))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.model == nil && row.preset == nil)
        .help(starred ? String(localized: "Remove \(row.name) from starred") : String(localized: "Star \(row.name) with its current effort"))
        .accessibilityIdentifier("agent-model-star")
    }
}

/// A tab of the panel's strip, as the page draws it: muted until it is the open one, which
/// reads in plain text over a line in the accent; filled under the pointer.
private struct AgentPanelTab<Label: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 32, height: 28)
                .foregroundStyle(selected || hovering ? Theme.chatPanelText : Theme.chatPanelMuted.opacity(0.7))
                .background(hovering ? Theme.chatPanelHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(Theme.chatPanelAccent).frame(height: 2).padding(.horizontal, 6).offset(y: 4) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A footer row: a title, and what it is set to with a chevron when a menu opens from it; filled
/// under the pointer.
private struct AgentPanelFooterRow: View {
    let title: String
    let value: String?
    let opens: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(value == nil ? Theme.chatPanelText : Theme.chatPanelMuted)
            Spacer(minLength: 0)
            if let value {
                Text(value).foregroundStyle(Theme.chatPanelText)
                if opens {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.chatPanelMuted)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(hovering ? Theme.chatPanelHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The effort as the page's slider card (`ComposerEffortSliderCard`): speed on the left where the
/// model has it, the level's name in the accent, reset to defaults on the right, and the ladder as
/// a stepped slider, every level one stop.
private struct AgentEffortSliderCard: View {
    let traits: AgentModelTraits
    let enabled: Bool
    let onEffort: (String) -> Void
    let onFastMode: (Bool) -> Void
    let onReset: () -> Void

    private var effortIsDefault: Bool { traits.locked || traits.effort == traits.defaultEffort }
    private var canReset: Bool { traits.fastModeEnabled || !effortIsDefault }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if traits.supportsFastMode {
                    iconButton(traits.fastModeEnabled ? "bolt.fill" : "bolt", tint: traits.fastModeEnabled ? Theme.chatPanelAccent : Theme.chatPanelMuted.opacity(0.7),
                               help: traits.fastModeEnabled ? String(localized: "Standard speed") : String(localized: "Fast mode")) {
                        onFastMode(!traits.fastModeEnabled)
                    }
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
                Text(traits.statusLabel ?? traits.effortLevels[safe: traits.ladderIndex]?.label ?? String(localized: "Effort"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.chatPanelAccent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                iconButton("arrow.counterclockwise", tint: Theme.chatPanelMuted.opacity(0.7), help: String(localized: "Reset to defaults"), action: onReset)
                    .disabled(!canReset)
                    .opacity(canReset ? 1 : 0.35)
            }
            AgentEffortSlider(count: traits.effortLevels.count, index: traits.ladderIndex, enabled: enabled && !traits.locked) { index in
                if let level = traits.effortLevels[safe: index] { onEffort(level.value) }
            }
            .padding(.horizontal, 2)
            if traits.locked {
                Text(String(localized: "Remove Ultrathink from the prompt to change effort."))
                    .font(.system(size: 12)).foregroundStyle(Theme.chatPanelMuted.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 4)
        .accessibilityIdentifier("agent-effort-card")
    }

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// A stepped slider on the panel's accent, every stop a dot under the thumb's centre; the fill
/// runs to the thumb. A drag or a click lands on the nearest stop.
private struct AgentEffortSlider: View {
    let count: Int
    let index: Int
    let enabled: Bool
    let onChange: (Int) -> Void
    @State private var dragging: Int?

    private let thumb: CGFloat = 28
    private let track: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let inner = max(geometry.size.width - thumb, 0)
            let shown = dragging ?? index
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chatPanelText.opacity(0.14)).frame(height: track)
                Capsule().fill(Theme.chatPanelAccent).frame(width: left(of: shown, inner: inner) + thumb, height: track)
                ForEach(0..<max(count, 0), id: \.self) { stop in
                    Circle()
                        .fill(stop <= shown ? Color.white.opacity(0.75) : Theme.chatPanelText.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .offset(x: left(of: stop, inner: inner) + thumb / 2 - 2)
                }
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.14), radius: 2, x: 0, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: left(of: shown, inner: inner))
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in if enabled { dragging = nearest(value.location.x, inner: inner) } }
                .onEnded { value in
                    guard enabled else { return }
                    let landed = nearest(value.location.x, inner: inner)
                    dragging = nil
                    if landed != index { onChange(landed) }
                })
        }
        .frame(height: thumb)
        .opacity(enabled ? 1 : 0.64)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: index)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Reasoning effort"))
        .accessibilityValue("\(index + 1) of \(count)")
    }

    /// The thumb's left edge at `stop`.
    private func left(of stop: Int, inner: CGFloat) -> CGFloat {
        count > 1 ? inner * CGFloat(stop) / CGFloat(count - 1) : 0
    }

    private func nearest(_ x: CGFloat, inner: CGFloat) -> Int {
        guard count > 1, inner > 0 else { return 0 }
        return min(max(Int(((x - thumb / 2) / inner * CGFloat(count - 1)).rounded()), 0), count - 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
