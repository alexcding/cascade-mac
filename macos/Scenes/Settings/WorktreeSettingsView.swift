import AppKit
import SwiftUI

/// Settings → Worktrees: the options that are about the machine rather than the repo — where a
/// session's new worktree is made, whether it fetches first, the default files it gets, and what
/// removing it also removes. A project's setup script and its own patterns live in its settings.
/// Every field is a config key the backend reads when the next worktree is made
/// (`crates/cascade-backend/src/worktrees.rs`), so nothing here touches a worktree that already exists.
struct WorktreeSettingsView<SaveRow: View>: View {
    @Bindable var model: SettingsViewModel
    @ViewBuilder var saveRow: SaveRow

    var body: some View {
        Group {
            Section("Location") {
                SettingsRow(title: String(localized: "New worktrees"), caption: model.draft.worktreeLocation.example) {
                    Picker("Worktree location", selection: $model.draft.worktreeLocation) {
                        ForEach(WorktreeLocation.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().accessibilityIdentifier("settings-worktree-location")
                }
                if model.draft.worktreeLocation == .custom {
                    SettingsRow(title: String(localized: "Folder"), caption: String(localized: "Each project gets its own folder inside it.")) {
                        HStack {
                            TextField("~/worktrees", text: $model.draft.worktreeRoot)
                                .accessibilityIdentifier("settings-worktree-root")
                            Button("Choose…", action: chooseRoot)
                        }
                    }
                }
                SettingsRow(title: String(localized: "Always fetch before creating worktrees"),
                            caption: String(localized: "Fetch the base branch before creating a worktree. Stop waiting after eight seconds and use the local branch if fetching fails.")) {
                    Toggle("Fetch before creating", isOn: $model.draft.worktreeFetch)
                        .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("settings-worktree-fetch")
                }
            }
            Section("Copy ignored files") {
                Text("Copy ignored files that match these patterns into new worktrees. Use one .gitignore pattern per line. Existing files are never overwritten. A project's patterns override this default; a repository's .worktreeinclude overrides both. Configure setup scripts in project settings.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $model.draft.worktreeInclude)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 72)
                    .accessibilityIdentifier("settings-worktree-include")
            }
            Section("Cleanup") {
                SettingsRow(title: String(localized: "Delete the branch when removing a worktree"),
                            caption: String(localized: "Delete only fully merged branches. Keep branches with unmerged work.")) {
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
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.draft.worktreeRoot = url.path
    }
}
