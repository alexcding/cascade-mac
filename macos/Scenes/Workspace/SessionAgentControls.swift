import AppKit
import SwiftUI

/// A key combination that switches to a preset while the session's window is in front.
struct AgentShortcut: Codable, Equatable, Sendable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    var modifiers: EventModifiers {
        var value: EventModifiers = []
        if command { value.insert(.command) }
        if option { value.insert(.option) }
        if control { value.insert(.control) }
        if shift { value.insert(.shift) }
        return value
    }
    var keyboardShortcut: KeyboardShortcut? {
        key.count == 1 ? key.first.map { KeyboardShortcut(KeyEquivalent($0), modifiers: modifiers) } : nil
    }
    /// As the menu bar writes them: ⌃⌥⇧⌘ then the key.
    var title: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }
}

// An extension, so the memberwise initialiser stays.
extension AgentShortcut {
    /// Nil for a press that cannot be a shortcut: no key, or none of ⌘ ⌃ ⌥ held, which would
    /// take an ordinary letter away from the terminal.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]),
              let pressed = event.charactersIgnoringModifiers?.lowercased(), pressed.count == 1,
              pressed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        key = pressed
        command = flags.contains(.command); option = flags.contains(.option)
        control = flags.contains(.control); shift = flags.contains(.shift)
    }
}

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
            AgentPreset(id: "default-\($0.id)", selection: AgentSelection(model: $0.id, effort: $0.defaultEffort ?? $0.efforts.first?.id))
        }
    }
}

/// The agent's controls, one group in the centre of a session's toolbar: what it is running, as a
/// menu of presets to switch to, then the context readout with its conversation actions. The
/// toolbar gives the item its glass, so everything inside is flat and shares the one capsule. It
/// holds a driver and a catalog, and never asks which CLI they belong to.
struct SessionAgentControlsView: View {
    let model: SessionWorkspaceViewModel
    let driver: any AgentDriver
    @AppStorage private var list: AgentPresetList
    @State private var configuring = false
    @State private var confirmingClear = false
    @State private var hoveringModel = false
    @State private var hoveringContext = false
    private let rowHeight: CGFloat = 26

    init(model: SessionWorkspaceViewModel, driver: any AgentDriver) {
        self.model = model; self.driver = driver
        _list = AppStorage(wrappedValue: AgentPresetList(), "workspace.agentPresetList.\(driver.cli)")
    }

    private var presets: [AgentPreset] { list.resolved(in: model.agentCatalog) }

    var body: some View {
        HStack(spacing: 3) {
            modelMenu
            // A hairline, not a `Divider`: the two halves are one control, not two sections.
            Rectangle().fill(Theme.border).frame(width: 1, height: 14)
            contextButton
            if let error = model.agentCommandError {
                // No room for a sentence in the toolbar: the mark says something failed, the tip says what.
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    .padding(.trailing, 6).help(error).accessibilityLabel(error)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .fixedSize()
        .background { shortcuts }
        .task(id: model.agentStatusTrigger) { await model.watchAgentStatus() }
        .accessibilityIdentifier("workspace-agent-controls")
    }

    private func title(_ selection: AgentSelection) -> (model: String, effort: String?) {
        let listed = model.agentCatalog.model(selection.model)
        return (listed?.name ?? selection.model, listed?.efforts.first { $0.id == selection.effort }?.name)
    }

    private func isActive(_ selection: AgentSelection) -> Bool {
        guard let running = model.agentSelection else { return false }
        let catalog = model.agentCatalog
        return catalog.model(selection.model)?.id == (catalog.model(running.model)?.id ?? running.model) && selection.effort == running.effort
    }

    private var modelMenu: some View {
        Menu {
            // The button always names what the agent is really running. When that is none of the
            // presets, say so here too, so an unticked list is not a puzzle.
            if let running = model.agentSelection, !presets.contains(where: { isActive($0.selection) }) {
                let name = title(running)
                Text("Running \([name.model, name.effort].compactMap { $0 }.joined(separator: " · ")), not a preset")
                Divider()
            }
            ForEach(presets) { preset in
                let name = title(preset.selection)
                let label = [name.model, name.effort].compactMap { $0 }.joined(separator: " · ")
                Toggle(preset.shortcut.map { "\(label)    \($0.title)" } ?? label,
                       isOn: Binding(get: { isActive(preset.selection) }, set: { _ in model.switchAgent(to: preset.selection) }))
                    .disabled(!model.canSendAgentCommand)
            }
            Divider()
            Button("Edit Presets…") { configuring = true }
        } label: {
            let running = model.agentSelection.map(title)
            // The model is what you read; its effort is a badge beside it, not a second word.
            HStack(spacing: 6) {
                Text(running?.model ?? "Model").fontWeight(.medium)
                if let effort = running?.effort {
                    Text(effort)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.surfaceHover, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(hoveringModel ? Theme.surfaceHover.opacity(0.6) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .onHover { hoveringModel = $0 }
        .help("Switch the agent’s model and effort")
        .popover(isPresented: $configuring, arrowEdge: .bottom) {
            AgentPresetEditor(catalog: model.agentCatalog, presets: Binding(get: { presets }, set: { list.presets = $0 }))
        }
    }

    /// The presets' shortcuts, as buttons nobody sees: a menu's items only answer their keys
    /// while the menu is open, and these answer whenever the window is in front.
    private var shortcuts: some View {
        ZStack {
            ForEach(presets) { preset in
                if let shortcut = preset.shortcut?.keyboardShortcut {
                    Button("") { model.switchAgent(to: preset.selection) }.keyboardShortcut(shortcut)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(!model.canSendAgentCommand)
        .accessibilityHidden(true)
    }

    /// The same kind of menu as the model beside it: the readout is the button, and what can be
    /// done about a full context drops down from it.
    private var contextButton: some View {
        Menu {
            Text(contextHelp)
            Divider()
            Button("Compact Conversation", systemImage: "arrow.down.right.and.arrow.up.left", action: model.compactAgent)
            Button("Clear Conversation…", systemImage: "eraser", role: .destructive) { confirmingClear = true }
        } label: {
            HStack(spacing: 6) {
                if let fraction = model.agentStatus?.fraction { ContextRing(fraction: fraction, brand: Theme.agentTint(driver.cli)) }
                // Quieter than the model: it is a gauge to glance at, not the control's name.
                Text(contextTitle).font(.callout).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(hoveringContext && model.canSendAgentCommand ? Theme.surfaceHover.opacity(0.6) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .onHover { hoveringContext = $0 }
        .disabled(!model.canSendAgentCommand)
        .opacity(model.canSendAgentCommand ? 1 : 0.5)
        .help(contextHelp)
        .confirmationDialog("Clear this conversation?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive, action: model.clearAgent)
        } message: {
            Text("The agent forgets everything said so far. The worktree is not touched.")
        }
    }

    /// The ring carries the percentage, so the text is only the size.
    private var contextTitle: String {
        guard let status = model.agentStatus else { return "Context" }
        return status.tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private var contextHelp: String {
        guard let status = model.agentStatus else { return "Compact or clear the conversation" }
        guard let fraction = status.fraction, let window = status.window else {
            return "The agent has not reported its context window, so there is no percentage"
        }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return "\(percent) of a \(window.formatted(.number.notation(.compactName))) context in use"
    }
}

/// How full the context is: a full ring, the used part in the agent's brand colour and the rest a
/// lighter shade of it.
private struct ContextRing: View {
    let fraction: Double
    let brand: Color

    var body: some View {
        ZStack {
            // The whole circle, in a lighter shade of the used part: what is left, not a gap.
            Circle().stroke(tint.opacity(0.28), lineWidth: 3)
            Circle().trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }

    /// The agent's own colour for what it has used, until it is nearly out: then the warning
    /// matters more than whose context it is.
    private var tint: Color { fraction > 0.9 ? Theme.danger : brand }
}

/// Any number of presets: a model, its effort, and the shortcut that switches to it.
private struct AgentPresetEditor: View {
    let catalog: AgentCatalog
    @Binding var presets: [AgentPreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presets) { preset in
                let efforts = catalog.model(preset.selection.model)?.efforts ?? []
                HStack(spacing: 8) {
                    Picker("Model", selection: Binding(get: { catalog.model(preset.selection.model)?.id ?? preset.selection.model },
                                                       set: { select($0, for: preset.id) })) {
                        ForEach(catalog.models) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 150)
                    Picker("Effort", selection: Binding(get: { preset.selection.effort ?? "" },
                                                        set: { effort in change(preset.id) { $0.selection.effort = effort } })) {
                        ForEach(efforts) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 110)
                    .disabled(efforts.isEmpty)
                    ShortcutRecorder(shortcut: Binding(get: { preset.shortcut }, set: { value in assign(value, to: preset.id) }))
                    Button("Remove Preset", systemImage: "minus.circle") { presets.removeAll { $0.id == preset.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(presets.count == 1)
                }
                .labelsHidden()
            }
            Button("Add Preset", systemImage: "plus") {
                guard let first = catalog.models.first else { return }
                presets.append(AgentPreset(selection: AgentSelection(model: first.id, effort: first.defaultEffort ?? first.efforts.first?.id)))
            }
            .disabled(catalog.models.isEmpty)
            Text("A shortcut needs ⌘, ⌃ or ⌥. It works while this window is in front; one the terminal or a menu already uses will not reach it.")
                .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
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
                preset.selection.effort = chosen.defaultEffort ?? chosen.efforts.first?.id
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

/// Click, then press the combination. Escape leaves it as it was; Delete clears it.
private struct ShortcutRecorder: View {
    @Binding var shortcut: AgentShortcut?
    @State private var monitor: Any?

    var body: some View {
        Button(monitor != nil ? "Press keys…" : shortcut?.title ?? "Add Shortcut") { monitor == nil ? start() : stop() }
            .frame(width: 96)
            .help("Click, then press a combination with ⌘, ⌃ or ⌥. Delete clears it.")
            .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; stop(); return nil }
            if let value = AgentShortcut(event: event) { shortcut = value; stop() }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
