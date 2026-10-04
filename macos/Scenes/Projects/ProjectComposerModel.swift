import Foundation
import Observation

/// A project's Start page: where every session in the project begins. One field takes a task for
/// the agent, a GitHub pull request, GitHub issue or Jira link to start on, or — with Shell only, or when it names
/// a branch the repository has — a branch, read by shape, with a hint saying which reading won.
/// A task gets a new branch named from its words, and becomes the agent's first prompt — or, with
/// Existing branch chosen, works on the chosen branch itself.
@MainActor @Observable final class ProjectComposerModel {
    enum Action: Equatable { case created(WorkspaceSession, prompt: String?, launch: AgentLaunchChoice?) }
    /// What the chosen branch is for: forking a new branch from it, or working on it.
    enum BranchMode: Equatable { case newBranch, existing }

    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    var text = "" { didSet { if oldValue != text { textChanged() } } }
    /// "Branch for that pull request" — only when a pasted PR's head branch couldn't be looked up.
    var pullRequestBranch = ""
    /// "Branch from": what a new branch forks from.
    var base = ""
    var branchMode: BranchMode = .newBranch
    /// With `.existing`, the branch the session works on. Empty until one is picked: the base would
    /// usually be the main checkout's branch, and starting on it moves that checkout.
    var workBranch = ""
    private(set) var agent: SessionAgent
    /// What each agent CLI offers, by CLI, once its catalog has been read.
    private(set) var catalogs: [String: AgentCatalog] = [:]
    /// The CLIs whose catalog is being read.
    private(set) var loadingCatalogs: Set<String> = []
    /// The model and effort picked for each CLI, by CLI: kept across sessions and projects.
    private(set) var choices: [String: AgentSelection] = ProjectComposerModel.savedChoices()
    /// Reads a CLI's catalog; set once the backend is there.
    @ObservationIgnored var catalogSource: ((String) async -> AgentCatalog?)? { didSet { loadCatalog() } }
    /// The ticket a link put here references (a PR row's Jira key), kept with the text it came
    /// with: recorded on the session created from that same text when its lookup names none.
    private(set) var linkedKey: (text: String, key: String)?
    private(set) var branches: [String] = []
    /// The typed address, resolved: its title, branch, and an existing checkout to reuse.
    private(set) var resolved: SessionDraft?
    /// A pasted PR whose lookup failed — the page then asks for its branch.
    private(set) var unresolvedPullRequest = false
    private(set) var loading = false
    private(set) var resolving = false
    private(set) var creating = false
    /// A lookup or create failure — cleared when the field changes.
    private(set) var error: String?
    private(set) var inputError: String?
    /// The branch list couldn't be read — independent of what is typed, so edits don't clear it.
    private(set) var referenceError: String?
    /// Bumped to put the keyboard in the field, when the page is opened to start something.
    private(set) var focusRequest = 0
    /// Start is on screen. Only then is the branch list read: a project opened once and left
    /// does not reread it on every reconnect.
    private(set) var shown = false
    private var viewers = 0
    private(set) var retired = false
    private var project: Project
    private var operations: (any SessionCreating)?
    /// Branches checked out in worktrees: a task never takes one of these names either.
    private var worktreeBranches: some Sequence<String> { checkouts.keys }
    /// Where each branch is checked out, and whether that is the main checkout.
    private(set) var checkouts: [String: (path: String, main: Bool)] = [:] { didSet { updateOwners() } }
    /// The project's sessions: a branch or worktree one already works on is not offered to another.
    private var sessions: [WorkspaceSession] = [] { didSet { if oldValue != sessions { updateOwners() } } }
    /// The session already working on each branch, by its branch or by the worktree that holds it.
    private var owners: [String: WorkspaceSession] = [:]
    private var generation = UUID()
    private var inputGeneration = UUID()
    @ObservationIgnored private var referenceTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private var lookup: Task<SessionDraft?, Never>? { didSet { oldValue?.cancel() } }

    init(project: Project, agent: SessionAgent, operations: (any SessionCreating)?) {
        self.project = project; self.agent = agent; self.operations = operations
    }

    var busy: Bool { loading || resolving || creating }
    var catalog: AgentCatalog? { catalogs[agent.rawValue] }
    /// The model the agent starts on, or nil for the CLI's own default.
    var model: AgentCatalog.Model? { catalog?.model(choices[agent.rawValue]?.model) }
    /// The effort the agent starts on: one the chosen model offers, or nil for its default.
    var effort: String? {
        guard let model, let effort = choices[agent.rawValue]?.effort, model.efforts.contains(where: { $0.id == effort }) else { return nil }
        return effort
    }
    var launchChoice: AgentLaunchChoice? { agent == .shell || model == nil ? nil : AgentLaunchChoice(model: model, effort: effort) }
    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlish: Bool { typed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil }
    var page: SessionPage? { urlish ? SessionPage.parse(typed) : nil }
    /// Text that names a branch rather than a task: with Shell only, or one the repository has.
    private var namesBranch: Bool { page == nil && !urlish && (agent == .shell || branches.contains(typed)) }
    var showsPullRequestBranch: Bool { unresolvedPullRequest && page != nil }
    /// A link is typed: it names its own branch, so the chooser picks only what a new branch forks from.
    var linkTyped: Bool { urlish }
    /// The session works on the chosen branch itself. A link names its own branch, so it never does.
    var usesExistingBranch: Bool { branchMode == .existing && !urlish }
    /// The branch the chooser shows as picked, for what it is choosing now.
    var chosenBranch: String { usesExistingBranch ? workBranch : base }
    /// A saved model waits for its catalog: started before it arrives, the session would run on the
    /// CLI's default with nothing to say the choice was dropped.
    private var awaitingChoice: Bool { choices[agent.rawValue]?.model != nil && loadingCatalogs.contains(agent.rawValue) }
    var canStart: Bool {
        guard !retired, operations != nil, !busy, !awaitingChoice, !project.workspace.isEmpty, !(urlish && page == nil) else { return false }
        return usesExistingBranch ? !workBranch.isEmpty && owners[workBranch] == nil : !typed.isEmpty
    }
    /// Picks `branch` for what the chooser is choosing now; false when it can't be picked.
    @discardableResult func choose(_ branch: String) -> Bool {
        guard !retired, owner(of: branch) == nil else { return false }
        if usesExistingBranch { workBranch = branch } else { base = branch }
        return true
    }
    /// The session that keeps `branch` from being picked: only working on a branch is exclusive.
    func owner(of branch: String) -> WorkspaceSession? { usesExistingBranch ? owners[branch] : nil }
    func updateSessions(_ sessions: [WorkspaceSession]) {
        guard !retired else { return }
        let mine = sessions.filter { $0.projectId == project.id }
        if mine != self.sessions { self.sessions = mine }
    }
    private func updateOwners() {
        func normal(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let byWorktree = Dictionary(sessions.map { (normal($0.worktree), $0) }, uniquingKeysWith: { first, _ in first })
        var owners: [String: WorkspaceSession] = [:]
        for (branch, checkout) in checkouts where !checkout.path.isEmpty {
            if let owner = byWorktree[normal(checkout.path)] { owners[branch] = owner }
        }
        for session in sessions where owners[session.branch] == nil { owners[session.branch] = session }
        self.owners = owners
    }
    /// What is typed is read by its shape, not by who runs it — except on an existing branch, where it
    /// can only be what the session is for.
    var placeholderText: String {
        guard usesExistingBranch else { return String(localized: "Describe a task or branch, or paste a pull request, issue or Jira link") }
        return agent == .shell ? String(localized: "Name the session (optional)")
                               : String(localized: "Describe what to do on this branch (optional)")
    }

    /// The line under the field: what a pasted link resolved to, or why the text can't start a session.
    var hint: (text: String, isError: Bool)? {
        if let inputError { return (inputError, true) }
        if usesExistingBranch {
            if workBranch.isEmpty { return (String(localized: "Choose the branch to work on"), false) }
            if let owner = owners[workBranch] {
                return (String(localized: "“\(owner.title)” already works on \(workBranch)"), true)
            }
            switch checkouts[workBranch] {
            case let (path, main)? where !main:
                return (String(localized: "Opens \(workBranch) in \((path as NSString).lastPathComponent)"), false)
            case _?:
                return (String(localized: "Moves the main checkout off \(workBranch) and opens it in a worktree of its own"), false)
            case nil:
                return (String(localized: "Checks out \(workBranch) in a new worktree"), false)
            }
        }
        if typed.isEmpty { return nil }
        if urlish && page == nil { return (String(localized: "Not a GitHub pull request, GitHub issue or Jira issue link"), true) }
        if let page {
            if resolving { return (String(localized: "Looking it up…"), false) }
            if let resolved {
                let name = resolved.title.isEmpty ? (page.kind == "github" ? String(localized: "that pull request") : page.key) : resolved.title
                if let path = resolved.reuseWorktree {
                    return (String(localized: "Opens \(name) in \((path as NSString).lastPathComponent) on \(resolved.branch)"), false)
                }
                return (String(localized: "Opens \(name) on \(resolved.branch)"), false)
            }
            if unresolvedPullRequest { return (String(localized: "Name that pull request’s branch below"), false) }
        }
        return nil
    }

    private var shellBranch: String {
        typed.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    }
    private var taskBranch: String {
        ProjectSessionStart.uniqueBranch(ProjectSessionStart.branchName(for: typed), taken: Set(branches).union(worktreeBranches))
    }

    func connect(_ operations: (any SessionCreating)?) {
        guard !retired else { return }
        self.operations = operations
        if operations == nil { cancel() } else { reloadReferencesIfShown() }
    }

    func update(_ project: Project) {
        guard !retired else { return }
        let moved = project.workspace != self.project.workspace
        self.project = project
        if moved { reloadReferencesIfShown() }
    }

    /// A view of Start came on screen or left it. Two can show it — its project's page and New
    /// Session — and a switch between them brings the next on before the last goes, so it is shown
    /// while any is. Coming on reads the branch list afresh, since branches change while it is away.
    func setShown(_ shown: Bool) {
        guard !retired else { return }
        viewers = max(0, viewers + (shown ? 1 : -1))
        guard (viewers > 0) != self.shown else { return }
        self.shown = viewers > 0
        // Another project's Start may have picked since: the choice is the app's, not this page's.
        if shown { choices = Self.savedChoices(); loadCatalog() }
        reloadReferencesIfShown()
    }

    private func reloadReferencesIfShown() {
        guard shown, operations != nil else { return }
        referenceTask = Task { [weak self] in await self?.loadReferences() }
    }

    func select(_ agent: SessionAgent) {
        guard !retired else { return }
        self.agent = agent
        loadCatalog()
    }

    /// Nil goes back to the CLI's default model. A model keeps the effort picked before only if it offers it.
    func chooseModel(_ id: String?) {
        guard !retired, agent != .shell else { return }
        guard let id else { choices[agent.rawValue] = nil; saveChoices(); return }
        choices[agent.rawValue] = AgentSelection(model: id, effort: choices[agent.rawValue]?.effort)
        saveChoices()
    }

    /// Nil leaves the effort to the model's default. Only a chosen model has efforts to pick.
    func chooseEffort(_ id: String?) {
        guard !retired, let model else { return }
        choices[agent.rawValue] = AgentSelection(model: model.id, effort: id)
        saveChoices()
    }

    private static let choicesKey = "startAgentChoices"
    private static func savedChoices() -> [String: AgentSelection] {
        guard let data = UserDefaults.standard.data(forKey: choicesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentSelection].self, from: data)) ?? [:]
    }
    private func saveChoices() {
        if let data = try? JSONEncoder().encode(choices) { UserDefaults.standard.set(data, forKey: Self.choicesKey) }
    }

    /// Reads the agent's catalog once, while Start is on screen; a CLI that cannot be asked offers no
    /// models, and starts on its default. A read that failed is tried again on the next call.
    func loadCatalog() {
        guard !retired, shown, agent != .shell, catalogs[agent.rawValue] == nil, let source = catalogSource,
              !loadingCatalogs.contains(agent.rawValue) else { return }
        let cli = agent.rawValue
        loadingCatalogs.insert(cli)
        Task { [weak self] in
            let catalog = await source(cli)
            guard let self else { return }
            loadingCatalogs.remove(cli)
            if let catalog, !catalog.models.isEmpty { catalogs[cli] = catalog }
        }
    }

    /// Opens the page to start something, on a link when one is given, with the ticket that
    /// link's pull request references.
    func prepare(text: String?, jiraKey: String? = nil, agent: SessionAgent?) {
        guard !retired else { return }
        if let agent { self.agent = agent; loadCatalog() }
        if let text {
            self.text = text
            let key = jiraKey?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            linkedKey = key.isEmpty ? nil : (text.trimmingCharacters(in: .whitespacesAndNewlines), key)
        }
        focusRequest += 1
    }

    func retire() {
        retired = true; operations = nil; onAction = { _ in }
        cancel()
    }

    private func cancel() {
        referenceTask = nil; generation = UUID(); loading = false
        inputGeneration = UUID(); resolving = false; lookup = nil
    }

    /// Every edit invalidates what the LAST text resolved to, then looks up a pasted address.
    private func textChanged() {
        inputGeneration = UUID()
        resolved = nil; unresolvedPullRequest = false; inputError = nil; error = nil
        lookup = nil; resolving = false
        guard !retired, page != nil else { return }
        lookup = Task { [weak self] in await self?.resolvePage() }
    }

    func loadReferences() async {
        guard !retired, !Task.isCancelled else { return }
        let generation = UUID(); self.generation = generation
        referenceError = nil
        guard let operations else { return }
        loading = true
        defer { if self.generation == generation { loading = false } }
        do {
            let refs = try await operations.references(project)
            try Task.checkCancellation()
            guard !retired, self.generation == generation else { return }
            var names = refs.branches.map(\.name)
            let sessionBase = refs.sessionBase
            if !names.contains(sessionBase) { names.insert(sessionBase, at: 0) }
            branches = names
            checkouts = Dictionary((refs.worktrees ?? []).compactMap { tree in
                tree.branch.map { ($0, (tree.path ?? "", tree.isMain == true)) }
            }, uniquingKeysWith: { first, _ in first })
            if base.isEmpty || !names.contains(base) { base = sessionBase }
            if !names.contains(workBranch) { workBranch = "" }
        } catch {
            if !retired && !Task.isCancelled && self.generation == generation { referenceError = error.localizedDescription }
        }
    }

    /// Resolve the typed address now (or wait for the lookup already running).
    @discardableResult func resolve() async -> Bool { await currentLookup() != nil }

    private func currentLookup() async -> SessionDraft? {
        if let resolved { return resolved }
        if let lookup { return await lookup.value }
        let task = Task { [weak self] in await self?.resolvePage() }
        lookup = task
        return await task.value
    }

    private func resolvePage() async -> SessionDraft? {
        guard !retired, !Task.isCancelled, let operations, let page, !resolving else { return nil }
        let generation = inputGeneration
        resolving = true; error = nil
        defer { if inputGeneration == generation { resolving = false } }
        var draft = SessionDraft(); draft.agent = agent; draft.base = base
        do {
            let result = try await operations.resolvePage(page.url, project: project, draft: draft)
            guard !retired, !Task.isCancelled, inputGeneration == generation else { return nil }
            resolved = result
            return result
        } catch {
            guard !retired, !Task.isCancelled, inputGeneration == generation else { return nil }
            if error is PullRequestBranchUnknown { unresolvedPullRequest = true } else { self.error = error.localizedDescription }
            return nil
        }
    }

    func submit() async {
        guard canStart, !Task.isCancelled, let operations else { return }
        let generation = inputGeneration
        creating = true; error = nil; inputError = nil
        defer { creating = false }
        var creation = SessionDraft(); creation.agent = agent; creation.base = base
        let launch = launchChoice
        var prompt: String?
        var workedOnExisting = false
        if let page {
            // A finished lookup that failed must not be reused: Create tries again.
            if resolved == nil { lookup = nil }
            if let found = await currentLookup() {
                creation.url = found.url; creation.kind = found.kind; creation.jiraKey = found.jiraKey
                creation.title = found.title; creation.branch = found.branch
                creation.createBranch = found.createBranch; creation.reuseWorktree = found.reuseWorktree
            } else if unresolvedPullRequest {
                // A pull request needs its OWN head branch: a new one would check out a branch that
                // doesn't exist (its worktree adopts, it doesn't create).
                let branch = pullRequestBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else { inputError = String(localized: "Name the pull request’s branch"); return }
                if let problem = ProjectSessionStart.branchNameError(branch) { inputError = problem; return }
                creation.url = page.url; creation.kind = "github"; creation.branch = branch; creation.createBranch = false
            } else {
                if error == nil { error = String(localized: "Could not look up that page. Check the address and try again.") }
                return
            }
        } else if usesExistingBranch {
            // The chosen branch is the session's own. No base: the backend picks where the main
            // checkout is parked, should it hold the branch, and nothing forks.
            creation.branch = workBranch; creation.createBranch = false; creation.base = ""; workedOnExisting = true
            // A shell takes no prompt; what is typed still names the session.
            if !typed.isEmpty {
                creation.title = ProjectSessionStart.title(for: typed)
                if agent != .shell { prompt = typed }
            }
        } else if namesBranch {
            let branch = shellBranch
            if let problem = ProjectSessionStart.branchNameError(branch) { inputError = problem; return }
            creation.branch = branch; creation.createBranch = !branches.contains(branch)
        } else {
            creation.branch = taskBranch; creation.createBranch = true
            creation.title = ProjectSessionStart.title(for: typed)
            prompt = typed
        }
        guard !retired, !Task.isCancelled, inputGeneration == generation else { return }
        // A ticket the row's pull request references, when the lookup names none.
        if page != nil, creation.jiraKey.isEmpty, let linkedKey, linkedKey.text == typed { creation.jiraKey = linkedKey.key }
        let usedBranch = pullRequestBranch
        do {
            let session = try await operations.create(project: project, draft: creation)
            guard !retired else { return }
            // Only what this session was made from is cleared: text or a page put here while it was
            // being created — Start opened on a link meanwhile — stays for the next one.
            if inputGeneration == generation { text = "" }
            // The branch named for a pull request belongs to that one: it never carries over to a
            // link opened meanwhile, unless it was typed again since.
            if pullRequestBranch == usedBranch { pullRequestBranch = "" }
            // New branch, new worktree is the default: working on an existing branch is chosen per session.
            if workedOnExisting { branchMode = .newBranch; workBranch = "" }
            onAction(.created(session, prompt: prompt, launch: launch))
            // The new branch is the repository's now: the next task must not take its name.
            referenceTask = nil
            await loadReferences()
        } catch {
            if !retired { self.error = error.localizedDescription }
        }
    }
}
