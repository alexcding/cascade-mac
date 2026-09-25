import SwiftUI

struct ProjectEditorView: View {
    @Bindable var model: ProjectEditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Project") {
                    TextField("Name", text: $model.draft.name).accessibilityIdentifier("project-name")
                    HStack {
                        TextField("Workspace folder", text: $model.draft.workspace).accessibilityIdentifier("project-workspace")
                        Button("Choose…") { Task { await model.pickFolder() } }
                    }
                    HStack {
                        TextField("GitHub repository", text: $model.draft.repo).help("owner/repo or a GitHub URL")
                        Button("Detect") { Task { await model.detectRepository() } }.disabled(model.draft.workspace.isEmpty)
                    }
                }
                Section("Jira") {
                    TextField("Project key", text: $model.draft.jiraProjectKey)
                    TextField("Saved JQL", text: $model.draft.jql, axis: .vertical).lineLimit(2...4)
                }
                Section("Editor") {
                    Picker("IDE", selection: $model.draft.ide) {
                        ForEach(model.ideChoices) { Text($0.title).tag($0.id) }
                    }
                    if model.draft.ide == "custom" {
                        TextField("Command template", text: $model.draft.ideCmd)
                        Text("Use {path} for the checkout location.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Relative launch target", text: $model.draft.ideTarget)
                    Text("For example, App/App.xcworkspace. Leave blank to detect the Xcode target.").font(.caption).foregroundStyle(.secondary)
                }
                Section("New session worktrees") {
                    HStack(alignment: .top) {
                        TextField("Setup script", text: $model.draft.worktreeSetup, prompt: Text("./scripts/setup.sh or npm ci"), axis: .vertical)
                            .lineLimit(1...6).font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("project-worktree-setup")
                        Button("Choose…") { Task { await model.pickSetupScript() } }.disabled(model.draft.workspace.isEmpty)
                    }
                    Text("Runs in the new worktree in the background, using its branch’s script. $CASCADE_ROOT_PATH is the project folder; $CASCADE_WORKTREE_PATH is the worktree. Failures appear in Activity.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Copy ignored files", text: $model.draft.worktreeInclude, prompt: Text(".env*  (the default)"), axis: .vertical)
                        .lineLimit(1...6).font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("project-worktree-include")
                    Text("Copy ignored files from the project folder before setup runs. Enter one pattern per line, such as .env or config/*.local. Leave blank to use Settings → Worktrees defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(model.busy)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                if model.id != nil {
                    Button("Delete Project…", role: .destructive, action: model.requestDeletion).disabled(!model.canDelete)
                    Spacer()
                    if model.saved && !model.dirty { Text("Saved").foregroundStyle(.secondary) }
                    Button("Revert", action: model.revert).disabled(!model.dirty || model.busy)
                } else { Spacer() }
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.id == nil ? String(localized: "Create Project") : String(localized: "Save Project")) { Task { await model.save() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }
    }
}

/// The web New Project modal (index.html #modal + components/modal.js): a name, the local
/// checkout with its detected GitHub repo as a hint, the Jira key and the IDE. Everything else
/// is set later in the project's own Settings tab.
struct NewProjectSheet: View {
    @Bindable var model: ProjectEditorViewModel
    let cancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(String(localized: "New Project"))
            SheetField(String(localized: "Project Name")) {
                TextField("", text: $model.draft.name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("Project Name")
                    .accessibilityIdentifier("project-name")
            }
            SheetField(String(localized: "Local Git Repo"), last: true) {
                HStack(spacing: 8) {
                    TextField("/path/to/local/checkout", text: $model.draft.workspace)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("project-workspace")
                        .onSubmit { Task { await model.detectRepository() } }
                    Button("Choose…") { Task { await model.chooseWorkspace() } }
                        .controlSize(.small)
                }
                SheetHint(model.draft.repo.isEmpty
                    ? Text("Sets the terminal's working directory; the GitHub repo is auto-detected from its \(sheetCode("git")) origin.")
                    : Text("GitHub repo: \(sheetCode(model.draft.repo))"))
            }
            SheetSection(String(localized: "Jira")) {
                SheetField(String(localized: "Project Key"), last: true) {
                    TextField("", text: Binding(get: { model.draft.jiraProjectKey },
                                                           set: { model.draft.jiraProjectKey = $0.uppercased() }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Project Key")
                    SheetHint(Text("Sets the Jira project for Tickets and Sprint Board. Use a filter clause, such as \(sheetCode("component = iOS")), to narrow results."))
                }
            }
            .padding(.top, 14)
            SheetSection(String(localized: "Editor")) {
                SheetField(String(localized: "IDE"), last: model.draft.ide != "custom") {
                    Picker("IDE", selection: $model.draft.ide) {
                        ForEach(model.ideChoices) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("project-ide")
                    SheetHint(Text("The editor used to open session worktrees. Set a launch target in the project’s Settings tab."))
                }
                if model.draft.ide == "custom" {
                    SheetField(String(localized: "Command Template"), last: true) {
                        TextField("", text: $model.draft.ideCmd)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Command Template")
                        SheetHint(Text("Use \(sheetCode("{path}")) for the checkout location."))
                    }
                }
            }
            .padding(.top, 14)
            if let error = model.error {
                SheetHint(error, isError: true).padding(.top, 12)
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(model.busy)
        .onAppear { nameFocused = true }
    }
}

struct ProjectPageView: View {
    @Bindable var model: ProjectPageViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Project section", selection: Binding(get: { model.section }, set: model.selectSection)) {
                ForEach(model.availableSections) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch model.section {
            case .tickets:
                if let tickets = model.tickets { JiraTicketsView(model: tickets) }
            case .board:
                if let board = model.board { WebBoardView(model: board) }
            case .settings: ProjectEditorView(model: model.editor)
            case .workflows:
                if let workflows = model.workflows { WorkflowEditorView(model: workflows) }
            case .prs:
                HStack {
                    TextField("Search project pull requests", text: Binding(get: { model.search }, set: model.setSearch)).textFieldStyle(.roundedBorder)
                    Picker("State", selection: Binding(get: { model.state }, set: model.setState)) {
                        Text("Open PRs").tag("open"); Text("Merged").tag("merged"); Text("All").tag("all")
                    }.frame(width: 140).accessibilityIdentifier("project-pr-state")
                    if model.loading || model.refreshing { ProgressView().controlSize(.small) }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Retry pull requests", action: model.retry).disabled(model.refreshing)
                }
                if let error = model.actionError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if model.rows.isEmpty && model.refreshing {
                            Text("Refreshing pull requests…").foregroundStyle(.secondary).padding(.vertical, 20)
                        } else if model.rows.isEmpty && !model.loading && model.error == nil {
                            Text(model.project.repo.isEmpty ? String(localized: "Configure a GitHub repository in Settings to track pull requests.") : String(localized: "No matching pull requests."))
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                        ForEach(model.rows) { row in
                            DashboardCard(row: row, opening: model.opening.contains(row.id),
                                          open: { model.open(row) }, openTab: { model.open(row, inTab: true) },
                                          session: { model.openSession(row, agent: $0) },
                                          sessionMark: model.sessionMark(row))
                            Divider()
                        }
                    }
                }
            }
        }.task { await model.refresh() }
        .onDisappear(perform: model.cancelRefresh)
    }
}
