import SwiftUI

/// Settings → Shortcuts: every command's key, grouped as the menu bar groups them. Sections for
/// a grouped Form. A combination another command or macOS holds is refused, never taken.
struct ShortcutsSettingsView: View {
    let registry: ShortcutRegistry
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
                                             conflict: { registry.conflict($0, for: command) },
                                             rejected: { rejection = $0 })
                        }
                    }
                }
            }
        }
    }
}
