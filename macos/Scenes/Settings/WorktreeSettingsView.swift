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

/// What the worktree folder holds, as the folder holds it: a heading per project with what its
/// worktrees take together, then a row per worktree with its own size and Delete, which acts at
/// once. What no project claims comes last. A session's worktree is not listed (it goes with its
/// session), nor is one made beside or inside a checkout.
private struct ExistingWorktreesSection: View {
    @Bindable var model: WorktreeListViewModel
    private static let sizeWidth: CGFloat = 70

    /// Consecutive rows of one project: the model keeps them in the sidebar's order of projects.
    private var projects: [(id: String, name: String, worktrees: [ExistingWorktree])] {
        var groups: [(id: String, name: String, worktrees: [ExistingWorktree])] = []
        for worktree in model.worktrees {
            let id = worktree.projectID ?? ""
            if groups.last?.id == id { groups[groups.count - 1].worktrees.append(worktree); continue }
            groups.append((id, worktree.project.isEmpty ? String(localized: "No project") : worktree.project, [worktree]))
        }
        return groups
    }

    var body: some View {
        Section {
            if model.loaded && model.isEmpty {
                Text("No worktrees.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(projects, id: \.id) { project in
                HStack(spacing: 12) {
                    Text(project.name).fontWeight(.semibold).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.total(of: project.worktrees).map(Self.size) ?? "—")
                        .foregroundStyle(Theme.textSecondary).monospacedDigit()
                        .frame(width: Self.sizeWidth, alignment: .trailing)
                }
                ForEach(project.worktrees) { worktree in
                    HStack(spacing: 12) {
                        Text(worktree.name).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(model.sizes[worktree.path].map(Self.size) ?? "—")
                            .foregroundStyle(Theme.textSecondary).monospacedDigit()
                            .frame(width: Self.sizeWidth, alignment: .trailing)
                        if model.removing == worktree.path { ProgressView().controlSize(.small) }
                        Button("Delete", role: .destructive) { Task { await model.remove(worktree) } }
                            .disabled(model.removing != nil)
                            .accessibilityIdentifier("settings-worktree-delete-\(worktree.path)")
                    }
                    .padding(.leading, 16)
                    .help(worktree.path)
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        } header: {
            SettingsSectionHeader(title: String(localized: "Worktree cleanup"), busy: model.loading || model.measuring) {
                if let total = model.total { Text(Self.size(total)).monospacedDigit() }
                Button("Refresh") { model.refresh() }.disabled(model.loading || model.removing != nil)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
