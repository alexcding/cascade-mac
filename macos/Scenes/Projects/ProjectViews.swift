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
                    Toggle("Forward GitHub webhooks", isOn: $model.draft.forwardWebhooks)
                        .disabled(model.draft.repo.isEmpty)
                        .accessibilityIdentifier("project-forward-webhooks")
                    Text("Pull request events reach Cascade as they happen: this project's pull requests refresh and automations run at once. While Cascade runs, this adds a webhook to the repository, which needs admin access to it. GitHub allows one per repository, so only one person can forward it at a time. When off, this project's pull requests refresh when you look at them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Jira") {
                    TextField("Project key", text: $model.draft.jiraProjectKey)
                    Toggle("Show board", isOn: $model.draft.boardEnabled)
                        .disabled(JiraKeys.parse(model.draft.jiraProjectKey).isEmpty)
                        .accessibilityIdentifier("project-board-enabled")
                    Text("Shows this project’s Jira sprint board on the Board tab in Projects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("GitHub Issues") {
                    Toggle("Show the repository's issues in Tickets", isOn: $model.draft.issuesEnabled)
                        .disabled(model.draft.repo.isEmpty)
                        .accessibilityIdentifier("project-issues-enabled")
                    Text("Open issues assigned to you appear beside your Jira tickets in Projects.")
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
            }.formStyle(.grouped).backdropContentBackground().disabled(model.busy)
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

/// The project page's way back to Projects, as an automation's is to Automations.
struct ProjectBackButton: View {
    let model: ProjectPageViewModel
    var body: some View {
        Button { model.goBack() } label: {
            Label(String(localized: "Projects"), systemImage: "chevron.left")
        }
        .help(String(localized: "Back to Projects"))
        .accessibilityIdentifier("project-back")
    }
}

/// A project's screen: its Settings.
struct ProjectPageView: View {
    let model: ProjectPageViewModel
    var body: some View {
        ProjectEditorView(model: model.editor)
            .padding(.bottom, 16)
            .frame(maxWidth: Theme.Size.readableColumn)
            .frame(maxWidth: .infinity)
    }
}

/// Start: the question in the middle of the page, and at its foot what the session starts in — the
/// project and the branch — over the field, whose own row picks the agent, its model and effort.
struct ProjectComposerView: View {
    let project: Project
    @Bindable var model: ProjectComposerModel
    /// The projects Start can switch to, with what to do on a pick; empty on a project's own page.
    var projects: [Project] = []
    var onChooseProject: ((String) -> Void)?
    /// New Project, offered under the projects when Start can switch between them.
    var onNewProject: (() -> Void)?
    /// New Task's Task | Chat switch, leading the tray; nil on a project's own page.
    var modeControl: AnyView?
    @FocusState private var focused: Bool
    @State private var choosingBranch = false
    @State private var choosingProject = false
    @State private var choosingProjectFromTitle = false

    /// Whether Start can switch projects here: New Session's, not a project's own page.
    private var switchesProject: Bool { onChooseProject != nil && !projects.isEmpty }

    /// The question, its project's name underlined. Where Start can switch, the name opens the
    /// projects as the chip does: the sentence is split around it, so it is a button of its own.
    @ViewBuilder private var title: some View {
        let marker = "\u{FFFC}"
        let sentence = String(localized: "What should we build in \(marker)?")
        let parts = sentence.components(separatedBy: marker)
        if switchesProject, let onChooseProject, parts.count == 2 {
            HStack(spacing: 0) {
                Text(parts[0])
                Button { choosingProjectFromTitle.toggle() } label: {
                    Text(project.name).underline(pattern: .dot).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosingProjectFromTitle, arrowEdge: .bottom) {
                    ProjectPicker(projects: projects, current: project.id, choose: onChooseProject, newProject: onNewProject) {
                        choosingProjectFromTitle = false
                    }
                }
                .help(String(localized: "The project the session starts in"))
                .accessibilityIdentifier("project-composer-title-project")
                Text(parts[1])
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            .onChange(of: choosingProjectFromTitle) { _, open in if !open { focused = true } }
        } else {
            Text("What should we build in \(Text(project.name).underline(pattern: .dot))?")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            title.font(.system(size: 32)).tracking(-0.6).multilineTextAlignment(.center)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                // Where the session starts sits on a tray along the card's top, as the card's own header.
                ComposerTray {
                    if let modeControl { modeControl }
                    projectChip
                    if !model.branches.isEmpty { baseMenu }
                    Spacer(minLength: 0)
                    if model.busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
                    if !model.branches.isEmpty { newBranchToggle }
                } card: {
                    card
                }
                ComposerMessageLine {
                    if let error = model.error ?? model.referenceError {
                        Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                    } else if project.workspace.isEmpty {
                        Text("Choose the project folder in Settings to start sessions.").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 766)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true; model.setShown(true) }
        .onDisappear { model.setShown(false) }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
    }

    private var card: some View {
        ComposerCard {
            ComposerTextField(placeholder: model.placeholderText, text: $model.text, focused: $focused,
                              disabled: model.creating, identifier: "project-composer") { Task { await model.submit() } }
            if model.showsPullRequestBranch {
                TextField(String(localized: "Branch for that pull request"), text: $model.pullRequestBranch)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
                    .onSubmit { Task { await model.submit() } }
                    .accessibilityIdentifier("project-composer-pr-branch")
            }
            HStack(spacing: 12) {
                // The hint shares the agent's row, so the card never grows or shrinks as it comes and goes.
                if let hint = model.hint {
                    Label(hint.text, systemImage: hint.isError ? "exclamationmark.triangle" : "arrow.turn.down.right")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(hint.isError ? Theme.danger : Color.secondary)
                        .accessibilityIdentifier("project-composer-hint")
                }
                Spacer(minLength: 0)
                ComposerAgentMenu(model: model)
                // Creates the session and sends the field as its first message.
                ComposerStartButton(enabled: model.canStart, label: String(localized: "Create Session"),
                                    identifier: "project-composer-create") { Task { await model.submit() } }
            }
            .frame(minHeight: 32)
        }
    }

    /// The project the session starts in; where Start can switch, it opens the projects to pick from.
    @ViewBuilder private var projectChip: some View {
        if switchesProject, let onChooseProject {
            Button { choosingProject.toggle() } label: {
                ComposerChip(symbol: "folder", title: project.name, active: choosingProject)
            }
            .buttonStyle(.plain)
            .onChange(of: choosingProject) { _, open in if !open { focused = true } }
            .popover(isPresented: $choosingProject, arrowEdge: .top) {
                ProjectPicker(projects: projects, current: project.id, choose: onChooseProject, newProject: onNewProject) {
                    choosingProject = false
                }
            }
            .help(String(localized: "The project the session starts in"))
            .accessibilityIdentifier("project-composer-project")
        } else {
            ComposerChip(symbol: "folder", title: project.name, interactive: false)
                .accessibilityIdentifier("project-composer-project")
        }
    }

    /// Whether the session forks a new branch from the chip's, or works on the chip's branch itself.
    /// Either way it gets a worktree of its own. A link names its own branch, so it has no say then.
    private var newBranchToggle: some View {
        Toggle(String(localized: "New branch"), isOn: Binding(get: { !model.usesExistingBranch },
                                                              set: { model.branchMode = $0 ? .newBranch : .existing }))
            .toggleStyle(.checkbox).font(.system(size: 14)).tint(.primary)
            .foregroundStyle(Color.primary.opacity(0.85))
            .disabled(model.linkTyped)
            .padding(.trailing, 8)
            .help(model.linkTyped ? String(localized: "A link names its own branch. A new one forks from the branch you pick.")
                  : model.usesExistingBranch ? String(localized: "The session works on the branch you pick, in a worktree of its own.")
                  : String(localized: "The session gets a new branch, forked from the one you pick."))
            .accessibilityIdentifier("project-composer-branch-mode")
    }

    /// The chosen branch: the one a new branch forks from, or, with New branch off, the one the session works on.
    private var baseMenu: some View {
        Button { choosingBranch.toggle() } label: {
            ComposerChip(symbol: "arrow.triangle.branch",
                         title: model.usesExistingBranch
                            ? (model.workBranch.isEmpty ? String(localized: "Choose branch") : model.workBranch)
                            : model.base,
                         chevron: true, active: choosingBranch)
        }
        .buttonStyle(.plain).layoutPriority(1)
        // Back to the field when the popover closes, so Return starts the session.
        .onChange(of: choosingBranch) { _, open in if !open { focused = true } }
        .popover(isPresented: $choosingBranch, arrowEdge: .top) {
            BranchChooser(model: model) { choosingBranch = false }
        }
        .help(model.usesExistingBranch ? String(localized: "The branch this session works on")
                                       : String(localized: "The branch a new branch forks from"))
        .accessibilityLabel(!model.usesExistingBranch ? String(localized: "Branch from \(model.base)")
                            : model.workBranch.isEmpty ? String(localized: "Choose branch") : String(localized: "Work on \(model.workBranch)"))
        .accessibilityIdentifier("project-composer-branch")
    }
}

/// The project chip's popover: the projects, filtered by what is typed, and New Project under them.
/// New Task's Chat side also offers No Project…, a chat in a folder picked for it.
struct ProjectPicker: View {
    let projects: [Project]
    /// The project picked; nil when none is.
    let current: String?
    let choose: (String) -> Void
    let newProject: (() -> Void)?
    var noProject: (() -> Void)? = nil
    let done: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [Project] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(String(localized: "Search projects"), text: $query)
                    .textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = matches.first { pick(first.id) } }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(matches) { project in
                        PickerRow(symbol: "folder", title: project.name, selected: project.id == current) { pick(project.id) }
                    }
                }
                .padding(8)
            }
            // As tall as its rows, up to a limit: filtering shrinks it rather than leave a gap.
            .frame(height: min(CGFloat(max(matches.count, 1)) * 35 + 16, 340))
            .overlay {
                if matches.isEmpty { Text("No project matches").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if newProject != nil || noProject != nil {
                Divider()
                VStack(spacing: 1) {
                    if let noProject {
                        PickerRow(symbol: "questionmark.folder", title: String(localized: "No Project…"), selected: current == nil) {
                            done(); noProject()
                        }
                        .accessibilityIdentifier("project-composer-no-project")
                    }
                    if let newProject {
                        PickerRow(symbol: "plus", title: String(localized: "New Project")) { done(); newProject() }
                            .accessibilityIdentifier("project-composer-new-project")
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 300)
        .onAppear { searching = true }
    }

    private func pick(_ id: String) {
        choose(id); done()
    }
}

/// The agent the session starts, and — from its CLI's catalog — the model and effort it starts on.
private struct ComposerAgentMenu: View {
    let model: ProjectComposerModel

    private var title: String {
        guard let driver = model.agent.driver else { return SessionAgent.shell.label }
        guard let name = model.model?.name else { return driver.shortName }
        return name.localizedCaseInsensitiveContains(driver.shortName) ? name : "\(driver.shortName) \(name)"
    }
    private var effortName: String? {
        guard let effort = model.effort else { return nil }
        return model.model?.efforts.first { $0.id == effort }?.name
    }

    var body: some View {
        ComposerAgentButton(agent: model.agent, title: title, detail: effortName,
                            help: String(localized: "The agent, model and effort the session starts with"),
                            identifier: "project-composer-agent") { close in
            AgentChooser(model: model, done: close)
        }
    }
}

/// The agent menu's popover: the agent as tabs along the top, and under them the chosen agent's
/// models and that model's efforts side by side, so a model and its effort are picked together.
/// Picks keep it open; a click outside closes it.
private struct AgentChooser: View {
    let model: ProjectComposerModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // Every agent the app has a driver for, then a plain shell.
                ForEach(SessionAgent.allCases.filter { $0 != .shell } + [.shell]) { agent in
                    AgentTab(agent: agent, selected: model.agent == agent) { model.select(agent) }
                }
            }
            .padding(8)
            Divider()
            if model.agent == .shell {
                note(String(localized: "A shell has no model to choose."))
            } else if let catalog = model.catalog {
                HStack(alignment: .top, spacing: 0) {
                    column(String(localized: "Model")) {
                        ChoiceRow(title: String(localized: "Default"), selected: model.model == nil) { model.chooseModel(nil) }
                        ForEach(catalog.models) { option in
                            ChoiceRow(title: option.name, selected: model.model?.id == option.id) { model.chooseModel(option.id) }
                        }
                    }
                    .frame(width: 270)
                    Divider()
                    column(String(localized: "Effort")) {
                        if let chosen = model.model, !chosen.efforts.isEmpty {
                            ChoiceRow(title: String(localized: "Default"), selected: model.effort == nil) { model.chooseEffort(nil) }
                            ForEach(chosen.efforts) { option in
                                ChoiceRow(title: option.name, selected: model.effort == option.id) { model.chooseEffort(option.id) }
                            }
                        } else {
                            Text(model.model == nil ? String(localized: "The default model picks its own effort.")
                                                    : String(localized: "This model has no effort levels."))
                                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                    .frame(width: 190)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if model.loadingCatalogs.contains(model.agent.rawValue) {
                note(String(localized: "Loading models…"))
            } else {
                note(String(localized: "No models to choose from: the agent starts on its default."))
            }
        }
        .frame(width: 461)
        // A read that failed is tried again when the chooser opens.
        .onAppear { model.loadCatalog() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Start's branch popover: which branch, filtered by what is typed. Whether the session forks it or
/// works on it is the New branch checkbox beside it.
private struct BranchChooser: View {
    @Bindable var model: ProjectComposerModel
    let done: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.branches : model.branches.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let matches = matches
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(String(localized: "Filter branches"), text: $query)
                    .textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = matches.first(where: { model.owner(of: $0) == nil }) { pick(first) } }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(matches, id: \.self) { branch in
                        BranchRow(name: branch, checkout: model.checkouts[branch], selected: branch == model.chosenBranch,
                                  owner: model.owner(of: branch)) { pick(branch) }
                    }
                }
            }
            // A fixed height: filtering never resizes the popover under the pointer.
            .frame(height: 306)
            .overlay {
                if matches.isEmpty {
                    Text("No branch matches").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { searching = true }
    }

    private func pick(_ branch: String) {
        if model.choose(branch) { done() }
    }
}

private struct BranchRow: View {
    let name: String
    let checkout: (path: String, main: Bool)?
    let selected: Bool
    /// The session already on this branch, in Existing branch: the row can't be picked.
    var owner: WorkspaceSession?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(name).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let owner {
                    Text("In session").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceHover))
                        .help(String(localized: "“\(owner.title)” already works on this branch"))
                } else if let checkout {
                    Text(checkout.main ? String(localized: "main checkout") : (checkout.path as NSString).lastPathComponent)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceHover))
                        .help(checkout.main ? String(localized: "Checked out in the project folder") : checkout.path)
                }
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && owner == nil ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(owner != nil).opacity(owner == nil ? 1 : 0.55)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
