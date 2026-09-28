import SwiftUI

/// Settings → Text Editor → File Icons: which installed VS Code icon theme draws files, and a
/// field that installs one from a link.
struct FileIconSettingsSection: View {
    @Bindable var model: FileIconSettingsViewModel
    let shell: ShellStore

    private var busy: Bool { model.working != nil }

    var body: some View {
        Section {
            SettingsRow(title: String(localized: "Icon theme")) {
                HStack {
                    Picker("Icon theme", selection: Binding(get: { shell.fileIconTheme }, set: { model.choose($0, selection: shell) })) {
                        Text("None").tag("")
                        ForEach(model.themes) { Text($0.label).tag($0.id) }
                        if !shell.fileIconTheme.isEmpty && !model.themes.contains(where: { $0.id == shell.fileIconTheme }) {
                            Text("Not installed").tag(shell.fileIconTheme)
                        }
                    }
                    .labelsHidden().disabled(busy).accessibilityIdentifier("settings-file-icon-theme")
                    if model.themes.contains(where: { $0.id == shell.fileIconTheme }) {
                        Button("Remove") { Task { await model.removeSelected(selection: shell) } }
                            .disabled(busy).accessibilityIdentifier("settings-file-icon-remove")
                    }
                }
            }
            FileIconPreview().accessibilityIdentifier("settings-file-icon-preview")
            SettingsRow(title: String(localized: "Install")) {
                HStack {
                    TextField("Install", text: $model.link, prompt: Text("VS Code Marketplace or Open VSX link"))
                        .labelsHidden()
                        .onSubmit { Task { await model.install(selection: shell) } }
                        .accessibilityIdentifier("settings-file-icon-link")
                    Button("Install") { Task { await model.install(selection: shell) } }
                        .disabled(busy || model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings-file-icon-install")
                }
            }
            if let working = model.working {
                HStack { ProgressView().controlSize(.small); Text(working).foregroundStyle(Theme.textSecondary) }
            } else if let error = model.error ?? model.themeError {
                Text(error).foregroundStyle(Theme.danger)
            }
        } header: {
            Text("File Icons")
        } footer: {
            Text("Cascade comes with vscode-icons. Others install from Open VSX; themes only on the VS Code Marketplace, and themes that draw their icons with a font, are not supported.")
        }
    }
}

/// Common files as the chosen theme draws them, or as the app draws them with none.
private struct FileIconPreview: View {
    private static let names = [
        "Package.swift", "main.rs", "index.ts", "App.tsx",
        "package.json", "Cargo.toml", "README.md", "Dockerfile",
        ".gitignore", "Info.plist", "styles.css", "icon.png",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
            ForEach(Self.names, id: \.self) { name in
                HStack(spacing: 6) {
                    FileIcon(name: name) {
                        Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(Theme.textTertiary).frame(width: 16)
                    }
                    Text(verbatim: name).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
