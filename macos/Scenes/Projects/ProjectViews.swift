import AppKit
import SwiftUI

struct ProjectEditorView: View {
    @Bindable var model: ProjectEditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Project") {
                    TextField("Name", text: $model.draft.name).accessibilityIdentifier("project-name")
                    LabeledContent("Icon") { ProjectIconButton(icon: $model.draft.icon) }
                    HStack {
                        TextField("Workspace folder", text: $model.draft.workspace).accessibilityIdentifier("project-workspace")
                        Button("Choose…") { Task { await model.pickFolder() } }
                    }
                    HStack {
                        TextField("GitHub repository", text: $model.draft.repo).help("owner/repo or a GitHub URL")
                        Button("Detect") { Task { await model.detectRepository() } }.disabled(model.draft.workspace.isEmpty)
                    }
                    Toggle("Forward webhooks to automations", isOn: $model.draft.forwardWebhooks)
                        .disabled(model.draft.repo.isEmpty)
                        .accessibilityIdentifier("project-forward-webhooks")
                    Text("Pull request events reach automations as they happen. While Cascade runs, this adds a webhook to the repository, which needs admin access to it. GitHub allows one per repository, so only one person can forward it at a time. When off, automations check pull requests on the regular refresh schedule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Jira") {
                    TextField("Project key", text: $model.draft.jiraProjectKey)
                    Toggle("Show board", isOn: $model.draft.boardEnabled)
                        .disabled(JiraKeys.parse(model.draft.jiraProjectKey).isEmpty)
                        .accessibilityIdentifier("project-board-enabled")
                    Text("Adds a Board tab to this project with its Jira sprint board.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("GitHub Issues") {
                    Toggle("Show the repository's issues in My Tickets", isOn: $model.draft.issuesEnabled)
                        .disabled(model.draft.repo.isEmpty)
                        .accessibilityIdentifier("project-issues-enabled")
                    Text("Open issues assigned to you appear beside your Jira tickets on the Dashboard.")
                        .font(.caption).foregroundStyle(.secondary)
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
            // Under the form, level with its sections' edges: the grouped form insets them 10pt.
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.horizontal, 10)
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
            .padding(.horizontal, 10)
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
                HStack(spacing: 8) {
                    ProjectIconButton(icon: $model.draft.icon)
                    TextField("", text: $model.draft.name)
                        .textFieldStyle(.roundedBorder).focused($nameFocused)
                        .accessibilityLabel("Project Name")
                        .accessibilityIdentifier("project-name")
                }
            }
            SheetField(String(localized: "Project Folder"), last: true) {
                HStack(spacing: 8) {
                    TextField("", text: $model.draft.workspace)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Project Folder")
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

/// A project's screen: the page its toolbar tabs pick (`ProjectTabBar`).
struct ProjectPageView: View {
    let model: ProjectPageViewModel
    var body: some View {
        switch model.section {
        case .start: ProjectComposerView(project: model.project, model: model.composer)
        case .board:
            if let board = model.board { ProjectBoardView(project: model.project, board: board) }
        case .settings:
            ProjectEditorView(model: model.editor)
                .padding(.bottom, 16)
                .frame(maxWidth: Theme.Size.readableColumn)
                .frame(maxWidth: .infinity)
        case .orchestration:
            ContentUnavailableView(String(localized: "Orchestration"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

/// The project's pages as the toolbar's leading item, standing in for its title as the
/// Dashboard's tabs do (`DashboardTabBar`).
struct ProjectTabBar: View {
    let sections: [ProjectSection]
    let selection: ProjectSection
    let select: (ProjectSection) -> Void

    var body: some View {
        Picker("Project section", selection: Binding(get: { selection }, set: select)) {
            ForEach(sections) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize()
        .accessibilityIdentifier("project-tabs")
    }
}

struct ProjectComposerView: View {
    let project: Project
    @Bindable var model: ProjectComposerModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Text("What are we working on in \(project.name)?")
                .font(.system(size: 24, weight: .semibold)).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                TextField(model.placeholderText, text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(3...10)
                    .frame(minHeight: 64, alignment: .topLeading)
                    .focused($focused).disabled(model.creating)
                    .onSubmit { Task { await model.submit() } }
                    // Return alone creates the session; with any modifier held — Shift, Option,
                    // Control or Command — it is a new line: the field editor's own, at the cursor.
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.subtracting([.capsLock, .numericPad]).isEmpty else { return .ignored }
                        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                        return .handled
                    }
                    .accessibilityIdentifier("project-composer")
                if model.showsPullRequestBranch {
                    TextField(String(localized: "Branch for that pull request"), text: $model.pullRequestBranch)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .onSubmit { Task { await model.submit() } }
                        .accessibilityIdentifier("project-composer-pr-branch")
                }
                if let hint = model.hint {
                    Text(hint.text).font(.system(size: 12))
                        .foregroundStyle(hint.isError ? Theme.danger : Color.secondary)
                        .accessibilityIdentifier("project-composer-hint")
                }
                HStack(spacing: 8) {
                    SegmentedChoice(options: [("Claude", SessionAgent.claude), ("Codex", .codex), (String(localized: "Shell only"), .shell)],
                                    selection: Binding(get: { model.agent }, set: model.select))
                    Spacer()
                    if !model.branches.isEmpty { baseMenu }
                    if model.busy { ProgressView().controlSize(.small) }
                    // Creates a session rather than sending a message, so it is not a send arrow.
                    Button { Task { await model.submit() } } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.canStart ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                    .disabled(!model.canStart)
                    .help(String(localized: "Create Session"))
                    .accessibilityLabel(String(localized: "Create Session"))
                    .accessibilityIdentifier("project-composer-create")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
            .frame(maxWidth: 620)
            if let error = model.error ?? model.referenceError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
            } else if project.workspace.isEmpty {
                Text("Choose the project folder in Settings to start sessions.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true; model.setShown(true) }
        .onDisappear { model.setShown(false) }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
    }

    /// "Branch from", drawn as the agent choice beside it is: plain text in an outline.
    private var baseMenu: some View {
        Menu {
            ForEach(model.branches, id: \.self) { branch in
                Button { model.base = branch } label: {
                    if branch == model.base { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(model.base)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "The branch a new branch forks from"))
        .accessibilityLabel(String(localized: "Branch from \(model.base)"))
    }
}

/// .theme-toggle / .theme-opt: plain text options, the chosen one outlined.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.1) { label, value in
                let on = value == selection
                Button { selection = value } label: {
                    Text(LocalizedStringKey(label)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color(nsColor: .separatorColor) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
