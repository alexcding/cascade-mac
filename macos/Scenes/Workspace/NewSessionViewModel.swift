import Foundation
import Observation

// The New Session sheet — src/renderer/components/new-session-dialog.js. It always creates the
// session under ONE project, fixed by where it was opened (a project's sidebar "+", the session
// or page in view); the sheet never offers another. One field takes either a branch name or the
// PR / ticket address the session is for, read by shape, with the hint saying which reading won.
@MainActor @Observable final class NewSessionViewModel {
    enum Action { case created(WorkspaceSession) }
    static let hint = "Also names the worktree folder — or paste a GitHub PR / Jira URL to start on that page."

    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let project: Project
    /// A plain page the sheet was opened from: the session's context when no PR / ticket is typed.
    let contextURL: String?
    /// "Branch name or URL".
    var input = "" { didSet { if oldValue != input { inputChanged() } } }
    /// "Branch for that pull request" — only when a pasted PR's head branch couldn't be looked up.
    var pullRequestBranch = ""
    /// Agent and "Branch from"; the page fields are filled by resolution.
    var draft = SessionDraft()
    private(set) var branches: [String] = []
    private(set) var placeholder = "worktree1"
    /// The typed address, resolved: its title, branch, and an existing checkout to reuse.
    private(set) var resolved: SessionDraft?
    /// A pasted PR whose lookup failed — the sheet then asks for its branch.
    private(set) var unresolvedPullRequest: SessionPage?
    private(set) var loading = false
    private(set) var creating = false
    private(set) var resolving = false
    private(set) var completed = false
    /// A lookup or create failure — cleared when the field changes.
    private(set) var error: String?
    private(set) var inputError: String?
    /// The branch list couldn't be read — independent of what is typed, so edits don't clear it.
    private(set) var referenceError: String?
    private var operations: (any SessionCreating)?
    private(set) var retired = false
    private var generation = UUID()
    private var inputGeneration = UUID()
    @ObservationIgnored private var referenceTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    @ObservationIgnored private var lookup: Task<SessionDraft?, Never>? { didSet { oldValue?.cancel() } }

    init(project: Project, contextURL: String? = nil, operations: (any SessionCreating)?) {
        self.project = project; self.operations = operations
        self.contextURL = contextURL.flatMap { SessionPage.parse($0) == nil ? $0 : nil }
    }

    private var active: Bool { !retired && !completed }
    var busy: Bool { loading || creating || resolving }
    var title: String { "New session on \(project.name.isEmpty ? "project" : project.name)" }
    private var typed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlish: Bool { typed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil }
    var page: SessionPage? { urlish ? SessionPage.parse(typed) : nil }
    var canCreate: Bool { active && operations != nil && !busy && !(urlish && page == nil) }
    var showsPullRequestBranch: Bool { unresolvedPullRequest != nil && page != nil }
    var reusedWorktree: String? { page == nil ? nil : resolved?.reuseWorktree }

    /// The line under the field (new-session-dialog.js `paint`), and whether it reads as an error.
    var fieldHint: (text: String, isError: Bool) {
        if let inputError { return (inputError, true) }
        guard !typed.isEmpty else { return (Self.hint, false) }
        if urlish && page == nil { return ("Not a GitHub pull request or Jira issue URL", true) }
        guard let page else { return (Self.hint, false) }
        if resolving { return ("Looking it up…", false) }
        if let resolved {
            let name = resolved.title.isEmpty ? (page.kind == "jira" ? page.key : "that pull request") : resolved.title
            return ("Opens \(name) — branch \(resolved.branch)", false)
        }
        if unresolvedPullRequest != nil { return ("Opens that pull request — name its branch below", false) }
        return (Self.hint, false)
    }

    var worktreeHint: String? {
        guard let path = reusedWorktree, let resolved else { return nil }
        return "Runs in \((path as NSString).lastPathComponent) on \(resolved.branch)"
    }

    /// Every edit invalidates what the LAST text resolved to, then looks up a pasted address.
    private func inputChanged() {
        inputGeneration = UUID()
        resolved = nil; unresolvedPullRequest = nil; inputError = nil; error = nil
        lookup = nil; resolving = false
        guard active, page != nil else { return }
        lookup = Task { [weak self] in await self?.resolvePage() }
    }

    func retire() {
        retired = true; operations = nil; onAction = { _ in }
        cancelReferenceLoading()
        inputGeneration = UUID(); resolving = false; lookup = nil
    }
    func cancelReferenceLoading() { referenceTask = nil; generation = UUID(); loading = false }

    func prepare() async {
        await loadReferences()
        guard active, !Task.isCancelled, page != nil, resolved == nil else { return }
        _ = await currentLookup()
    }

    func loadReferences() async {
        guard active, !Task.isCancelled else { return }
        let generation = UUID(); self.generation = generation
        branches = []; referenceError = nil; loading = false
        guard let operations else { return }
        loading = true
        defer { if self.generation == generation { loading = false } }
        do {
            let refs = try await operations.references(project)
            try Task.checkCancellation()
            guard active, self.generation == generation else { return }
            var names = refs.branches.map(\.name)
            let base = refs.sessionBase
            if !names.contains(base) { names.insert(base, at: 0) }
            branches = names
            if draft.base.isEmpty || !names.contains(draft.base) { draft.base = base }
            let taken = Set(names + (refs.worktrees ?? []).compactMap(\.branch))
            var index = 1
            while taken.contains("worktree\(index)") { index += 1 }
            placeholder = "worktree\(index)"
        } catch { if active && !Task.isCancelled && self.generation == generation { referenceError = error.localizedDescription } }
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
        guard active, !Task.isCancelled, let operations, let page, !resolving else { return nil }
        let generation = inputGeneration
        resolving = true; error = nil
        defer { if inputGeneration == generation { resolving = false } }
        do {
            let result = try await operations.resolvePage(page.url, project: project, draft: draft, workflow: false)
            guard active, !Task.isCancelled, inputGeneration == generation else { return nil }
            resolved = result
            return result
        } catch {
            guard active, !Task.isCancelled, inputGeneration == generation else { return nil }
            if error is PullRequestBranchUnknown { unresolvedPullRequest = page } else { self.error = error.localizedDescription }
            return nil
        }
    }

    func create() async {
        guard canCreate, !Task.isCancelled, let operations else { return }
        let generation = inputGeneration
        creating = true; error = nil; inputError = nil
        defer { creating = false }
        var creation = draft
        creation.title = ""; creation.kind = "session"; creation.jiraKey = ""; creation.reuseWorktree = nil
        if let page {
            // A finished lookup that failed must not be reused: Create tries again.
            if resolved == nil { lookup = nil }
            if let found = await currentLookup() {
                creation.url = found.url; creation.kind = found.kind; creation.jiraKey = found.jiraKey
                creation.title = found.title; creation.branch = found.branch
                creation.createBranch = found.createBranch; creation.reuseWorktree = found.reuseWorktree
            } else if unresolvedPullRequest != nil {
                // A pull request needs its OWN head branch: the placeholder would check out a
                // branch that doesn't exist (its worktree adopts, it doesn't create).
                let branch = pullRequestBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else { inputError = "Name the pull request’s branch"; return }
                if let problem = Self.branchNameError(branch) { inputError = problem; return }
                creation.url = page.url; creation.kind = "github"; creation.branch = branch; creation.createBranch = false
            } else {
                if error == nil { error = "Could not look up that page. Check the address and try again." }
                return
            }
        } else {
            let branch = (typed.isEmpty ? placeholder : typed).replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            if let problem = Self.branchNameError(branch) { inputError = problem; return }
            creation.branch = branch; creation.createBranch = !branches.contains(branch); creation.url = contextURL ?? ""
        }
        guard active, !Task.isCancelled, inputGeneration == generation else { return }
        do {
            let session = try await operations.create(project: project, draft: creation, requireExactBranch: false)
            guard active else { return }
            completed = true
            onAction(.created(session))
        } catch { if active { self.error = error.localizedDescription } }
    }

    /// The server's validBranchName, so a bad name is caught before the worktree call.
    static func branchNameError(_ branch: String) -> String? {
        if branch.isEmpty { return "Enter a branch name" }
        if branch.hasPrefix("-") || branch.hasSuffix("/") || branch.hasSuffix(".") || branch.hasSuffix(".lock") {
            return "Branch name can’t start with “-” or end with “/”, “.” or “.lock”"
        }
        if branch.range(of: #"[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|^@$"#, options: .regularExpression) != nil {
            return "Branch name can’t contain spaces, “..” or ~ ^ : ? * [ \\"
        }
        if !branch.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) {
            return "No branch segment may start with “.”"
        }
        return nil
    }
}
