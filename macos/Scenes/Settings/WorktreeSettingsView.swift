import AppKit
import SwiftUI

/// Settings → Worktrees: the options that are about the machine rather than the repo — where a
/// session's new worktree is made, whether it fetches first, and the default files it gets. A project's setup script and its own patterns live in its settings.
/// Every field is a config key the backend reads when the next worktree is made
/// (`crates/cascade-backend/src/worktrees.rs`), so none of them touches a worktree that already
/// exists. Those are listed under the form, each with its own Delete (`WorktreeListViewModel`).
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
                PlainTextEditor(text: $model.draft.worktreeInclude)
                    .frame(minHeight: 72)
                    .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    .accessibilityIdentifier("settings-worktree-include")
            }
            // The form's Save: its own group, so it reads as the form's footer. The list below it
            // is not saved; each Delete acts at once.
            Section { saveRow }
        }.disabled(!model.loaded || model.saving)
        ExistingWorktreesSection(model: model.worktrees)
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

/// What the worktree folder holds, a section per project and one for leftovers no project claims.
/// Worktrees made beside or inside a checkout are not listed.
private struct ExistingWorktreesSection: View {
    @Bindable var model: WorktreeListViewModel

    var body: some View {
        Section {
            Text("The worktrees in Cascade’s worktree folder. Deleting a project keeps them; delete them here. Delete removes the folder and anything not committed in it, with any sessions using it. Its local branch goes too, if Cascade made it and it is merged; any other branch is kept.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if model.loaded && model.isEmpty {
                Text("No worktrees.").foregroundStyle(Theme.textSecondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        } header: {
            SettingsSectionHeader(title: String(localized: "Existing worktrees"), busy: model.loading) {
                Button("Refresh", action: model.refresh).disabled(model.loading || model.removing != nil)
            }
        }
        ForEach(model.groups) { group in
            Section(group.title) {
                ForEach(group.worktrees) { worktree in
                    SettingsRow(title: worktree.name, caption: Self.caption(worktree)) {
                        HStack(spacing: 8) {
                            if model.removing == worktree.path { ProgressView().controlSize(.small) }
                            Button("Delete", role: .destructive) { Task { await model.remove(worktree) } }
                                .disabled(model.removing != nil)
                                .accessibilityIdentifier("settings-worktree-delete-\(worktree.path)")
                        }
                    }
                }
            }
        }
    }

    private static func caption(_ worktree: ExistingWorktree) -> String {
        var lines = [worktree.path]
        if !worktree.sessions.isEmpty {
            lines.append(String(localized: "Used by \(worktree.sessions.joined(separator: ", ")), which Delete also removes"))
        }
        if worktree.projectID == nil {
            lines.append(worktree.repo.isEmpty ? String(localized: "Its checkout is gone.")
                         : String(localized: "From \(worktree.repo), which is not a project."))
        }
        return lines.joined(separator: "\n")
    }
}
