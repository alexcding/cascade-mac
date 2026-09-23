import AppKit
import SwiftUI

/// Settings → Worktrees: the options that are about the machine rather than the repo — where a
/// session's new worktree is made, whether it fetches first, the default files it gets, and what
/// removing it also removes. A project's setup script and its own patterns live in its settings.
/// Every field is a config key the backend reads when the next worktree is made
/// (`crates/craft-backend/src/worktrees.rs`), so nothing here touches a worktree that already exists.
struct WorktreeSettingsView<SaveRow: View>: View {
    @Bindable var model: SettingsViewModel
    @ViewBuilder var saveRow: SaveRow

    var body: some View {
        Group {
            Section("Location") {
                SettingsRow(title: "New worktrees", caption: model.draft.worktreeLocation.example) {
                    Picker("Worktree location", selection: $model.draft.worktreeLocation) {
                        ForEach(WorktreeLocation.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityIdentifier("settings-worktree-location")
                }
                if model.draft.worktreeLocation == .custom {
                    SettingsRow(title: "Folder", caption: "Each project gets its own folder inside it.") {
                        HStack {
                            TextField("~/worktrees", text: $model.draft.worktreeRoot)
                                .accessibilityIdentifier("settings-worktree-root")
                            Button("Choose…", action: chooseRoot)
                        }
                    }
                }
                SettingsRow(title: "Always fetch before creating worktrees",
                            caption: "New branches are normally cut from the tip this checkout already has. This fetches the base branch first, for at most a few seconds.") {
                    Toggle("Fetch before creating", isOn: $model.draft.worktreeFetch)
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-worktree-fetch")
                }
            }
            Section("Copy ignored files") {
                Text("A new worktree only gets the files git tracks, so git-ignored ones like .env are missing. Files matching these patterns (one per line, .gitignore syntax) are copied in from the project folder. Only ignored files are copied, and nothing already in the worktree is overwritten. This is the default: a project can set its own in its Settings, and a .worktreeinclude file in the repository wins over both. The setup script is set per project.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $model.draft.worktreeInclude)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .accessibilityIdentifier("settings-worktree-include")
            }
            Section("Cleanup") {
                SettingsRow(title: "Delete the branch when removing a worktree",
                            caption: "Only a branch that is fully merged. Unmerged work keeps its branch.") {
                    Toggle("Delete merged branch", isOn: $model.draft.worktreeDeleteBranch)
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-worktree-delete-branch")
                }
            }
            // The whole page's Save, not Cleanup's: its own group, so it reads as the form's footer.
            Section { saveRow }
        }.disabled(!model.loaded || model.saving)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.draft.worktreeRoot = url.path
    }
}
