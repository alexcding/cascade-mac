import SwiftUI

/// Settings → Shortcuts: every command's key, grouped as the menu bar groups them. Sections for
/// a grouped Form. A combination another command or macOS holds is refused, never taken.
struct ShortcutsSettingsView: View {
    let registry: ShortcutRegistry
    @State private var rejection: String?

    var body: some View {
        Section {
            SettingsRow(title: "Keyboard shortcuts",
                        caption: rejection ?? "Click a shortcut, then press the new combination. Delete clears it.") {
                Button("Restore Defaults") { registry.resetAll(); rejection = nil }
                    .disabled(!registry.hasCustom)
                    .accessibilityIdentifier("settings-shortcuts-reset")
            }
        }
        ForEach(ShortcutGroup.allCases) { group in
            Section(group.rawValue) {
                ForEach(group.commands, id: \.self) { command in
                    SettingsRow(title: command.title) {
                        HStack(spacing: 6) {
                            if registry.isCustom(command) {
                                Button("Restore Default", systemImage: "arrow.uturn.backward") { rejection = registry.reset(command) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .help("Restore \(command.defaultShortcut?.title ?? "no shortcut")")
                            }
                            ShortcutRecorder(shortcut: Binding(get: { registry.shortcut(for: command) },
                                                               set: { registry.assign($0, to: command) }),
                                             placeholder: "None",
                                             conflict: { registry.conflict($0, for: command) },
                                             rejected: { rejection = $0 })
                        }
                    }
                }
            }
        }
    }
}
