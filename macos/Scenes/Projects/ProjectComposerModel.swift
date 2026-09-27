import Foundation
import Observation

/// A project's Start page: where every session in the project begins. One field takes a task for
/// the agent, a GitHub pull request, GitHub issue or Jira link to start on, or — with Shell only, or when it names
/// a branch the repository has — a branch, read by shape, with a hint saying which reading won.
/// A task gets a new branch named from its words, and becomes the agent's first prompt.
@MainActor @Observable final class ProjectComposerModel {
    enum Action: Equatable { case created(WorkspaceSession, prompt: String?) }

    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    var text = "" { didSet { if oldValue != text { textChanged() } } }
    /// "Branch for that pull request" — only when a pasted PR's head branch couldn't be looked up.
    var pullRequestBranch = ""
    /// "Branch from": what a new branch forks from.
    var base = ""
    private(set) var agent: SessionAgent
    /// A plain page the session was asked for from: its context, when no PR or ticket is typed.
    private(set) var contextURL: String?
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
    private(set) var retired = false
    private var project: Project
    private var operations: (any SessionCreating)?
    /// Branches checked out in worktrees: a task never takes one of these names either.
    private var worktreeBranches: [String] = []
    private var generation = UUID()
    private var inputGeneration = UUID()
    @ObservationIgnored private var referenceTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private var lookup: Task<SessionDraft?, Never>? { didSet { oldValue?.cancel() } }

    init(project: Project, agent: SessionAgent, operations: (any SessionCreating)?) {
        self.project = project; self.agent = agent; self.operations = operations
    }

    var busy: Bool { loading || resolving || creating }
    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlish: Bool { typed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil }
    var page: SessionPage? { urlish ? SessionPage.parse(typed) : nil }
    /// Text that names a branch rather than a task: with Shell only, or one the repository has.
    private var namesBranch: Bool { page == nil && !urlish && (agent == .shell || branches.contains(typed)) }
    var showsPullRequestBranch: Bool { unresolvedPullRequest && page != nil }
    var canStart: Bool {
        !retired && operations != nil && !busy && !project.workspace.isEmpty
            && !typed.isEmpty && !(urlish && page == nil)
    }
    /// The same for every agent: what is typed is read by its shape, not by who runs it.
    var placeholderText: String { String(localized: "Describe a task or branch, or paste a pull request, issue or Jira link") }

    /// The line under the field: what a pasted link resolved to, or why the text can't start a session.
    var hint: (text: String, isError: Bool)? {
        if let inputError { return (inputError, true) }
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
        ProjectSessionStart.uniqueBranch(ProjectSessionStart.branchName(for: typed), taken: Set(branches + worktreeBranches))
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

    /// Start came on screen or left it. Coming on reads the branch list afresh, since branches
    /// change while it is away.
    func setShown(_ shown: Bool) {
        guard !retired, shown != self.shown else { return }
        self.shown = shown
        reloadReferencesIfShown()
    }

    private func reloadReferencesIfShown() {
        guard shown, operations != nil else { return }
        referenceTask = Task { [weak self] in await self?.loadReferences() }
    }

    func select(_ agent: SessionAgent) {
        guard !retired else { return }
        self.agent = agent
    }

    /// Opens the page to start something: a link to start on, or the plain page it was asked from.
    func prepare(text: String?, contextURL: String?, agent: SessionAgent?) {
        guard !retired else { return }
        if let agent { self.agent = agent }
        self.contextURL = contextURL.flatMap { SessionPage.parse($0) == nil ? $0 : nil }
        if let text { self.text = text }
        focusRequest += 1
    }

    func clearContext() { guard !retired else { return }; contextURL = nil }

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
            worktreeBranches = (refs.worktrees ?? []).compactMap(\.branch)
            if base.isEmpty || !names.contains(base) { base = sessionBase }
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
        var prompt: String?
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
        } else if namesBranch {
            let branch = shellBranch
            if let problem = ProjectSessionStart.branchNameError(branch) { inputError = problem; return }
            creation.branch = branch; creation.createBranch = !branches.contains(branch); creation.url = contextURL ?? ""
        } else {
            creation.branch = taskBranch; creation.createBranch = true
            creation.title = ProjectSessionStart.title(for: typed); creation.url = contextURL ?? ""
            prompt = typed
        }
        guard !retired, !Task.isCancelled, inputGeneration == generation else { return }
        let usedContext = contextURL, usedBranch = pullRequestBranch
        do {
            let session = try await operations.create(project: project, draft: creation)
            guard !retired else { return }
            // Only what this session was made from is cleared: text or a page put here while it was
            // being created — Start opened on a link meanwhile — stays for the next one.
            if inputGeneration == generation { text = "" }
            // The branch named for a pull request belongs to that one: it never carries over to a
            // link opened meanwhile, unless it was typed again since.
            if pullRequestBranch == usedBranch { pullRequestBranch = "" }
            if contextURL == usedContext { contextURL = nil }
            onAction(.created(session, prompt: prompt))
            // The new branch is the repository's now: the next task must not take its name.
            referenceTask = nil
            await loadReferences()
        } catch {
            if !retired { self.error = error.localizedDescription }
        }
    }
}
