import Foundation

struct OperationOK: Decodable, Sendable { let ok: Bool? }

enum SessionAgent: String, CaseIterable, Identifiable, Sendable {
    case shell = "", claude, codex
    var id: String { rawValue }
    var label: String { switch self { case .shell: "Shell only"; case .claude: "Claude Code"; case .codex: "Codex" } }

    /// Nil for a shell-only session, which has no agent to drive.
    var driver: (any AgentDriver)? { self == .shell ? nil : AgentDrivers.driver(for: rawValue) }

    func command(sessionID: String?, fresh: Bool = false, statusLine: AgentStatusLine? = nil) -> String? {
        driver?.launchCommand(sessionID: sessionID, fresh: fresh, selection: nil, effort: nil, statusLine: statusLine)
    }
    static func quote(_ value: String) -> String { AgentDrivers.quote(value) }
}

/// A pull request whose head branch nothing could tell us — the only resolution failure the
/// New Session sheet answers by asking for the branch. Every other failure is a real error.
struct PullRequestBranchUnknown: LocalizedError, Sendable {
    var errorDescription: String? { "Could not look up this pull request’s branch." }
}

struct GitReferences: Decodable, Sendable {
    struct Branch: Decodable, Sendable { let name: String }
    struct Worktree: Decodable, Sendable { let branch: String? }
    let branches: [Branch]
    let defaultBranch: String
    var worktrees: [Worktree]? = nil

    /// The base a new session's branch forks from: `develop` when the repo has it, else its default.
    var sessionBase: String {
        let names = branches.map(\.name)
        if names.contains("develop") { return "develop" }
        return defaultBranch.isEmpty ? names.first ?? "develop" : defaultBranch
    }
}

struct SessionDraft: Equatable, Sendable {
    var branch = ""
    var base = ""
    var createBranch = true
    var title = ""
    var url = ""
    var agent: SessionAgent = .claude
    var kind = "session"
    var jiraKey = ""
    var reuseWorktree: String?
}

// Local git operations and durable records stay in the existing backend. A failed
// record write reports the created checkout so it is recoverable, never deleted.
protocol SessionCreating: Sendable {
    func references(_ project: Project) async throws -> GitReferences
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool) async throws -> SessionDraft
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool) async throws -> WorkspaceSession
    /// Moves `project`'s main checkout onto `branch`, freeing the one it holds for a worktree.
    func switchMainCheckout(to branch: String, project: Project) async throws
}

/// A session started straight from a PR or ticket page (viewer.js newSession): the page decides
/// the branch, an existing checkout is reused, and a new branch forks from the session base.
enum PageSessionStart {
    enum Outcome: Sendable {
        case created(WorkspaceSession)
        /// The PR's head branch couldn't be looked up — the New Session sheet asks for it.
        case needsBranch
        case failed(String)
    }

    /// `jiraKey` is the ticket a PR page references, recorded on the session so the ticket's row finds it too.
    static func run(url: String, project: Project, agent: SessionAgent, jiraKey: String = "", operations: any SessionCreating) async -> Outcome {
        do {
            var draft = SessionDraft(); draft.agent = agent
            draft = try await operations.resolvePage(url, project: project, draft: draft, workflow: false)
            if draft.jiraKey.isEmpty { draft.jiraKey = jiraKey.uppercased() }
            if draft.createBranch && draft.reuseWorktree == nil { draft.base = try await operations.references(project).sessionBase }
            return .created(try await operations.create(project: project, draft: draft, requireExactBranch: false))
        } catch is PullRequestBranchUnknown {
            return .needsBranch
        } catch {
            return .failed("Could not start session: \(error.localizedDescription)")
        }
    }
}

protocol SessionServing: SessionCreating {
    func saveAgentID(_ id: String, session: WorkspaceSession) async throws
    func conversationExists(cli: String, id: String) async throws -> Bool
    func configureAgent(_ cli: WorkflowCLI, session: WorkspaceSession) async throws -> WorkspaceSession
}

struct SessionOperations: SessionServing {
    let api: APIClient
    func references(_ project: Project) async throws -> GitReferences {
        try await api.get(APIClient.query(Routes.GIT_REFS, ["path": project.workspace]))
    }
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool = false) async throws -> WorkspaceSession {
        let branch = draft.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !project.workspace.isEmpty else { throw BackendError.operation("Choose a project workspace and branch.") }
        guard sourceURL.isEmpty || safeSessionURL(sourceURL) else { throw BackendError.operation("The page address must use HTTP or HTTPS.") }
        struct WorktreeRequest: Encodable, Sendable {
            let path: String; let branch: String; let create: Bool; let base: String
        }
        struct WorktreeResult: Decodable, Sendable { let path: String }
        let worktree: WorktreeResult
        if let reused = draft.reuseWorktree {
            let found: ResolvedWorktree = try await api.get(APIClient.query(Routes.WORKTREE,
                ["path": project.workspace, "branch": branch, "strict": "1"]))
            guard found.matched, found.isWorktree, SessionRemovalPlan.path(found.path) == SessionRemovalPlan.path(reused) else {
                throw BackendError.operation("The existing worktree changed. Resolve the page again before creating the session.")
            }
            worktree = .init(path: found.path)
        } else {
            // A branch that already has a WORKTREE here is reused — the session is new, the worktree
            // isn't. The main checkout is not one: it gets parked on the base, and the branch it was
            // holding then needs a worktree of its own like any other.
            let existing: ResolvedWorktree = try await api.get(APIClient.query(Routes.WORKTREE,
                ["path": project.workspace, "branch": branch, "strict": "1"]))
            let held = existing.matched && !existing.isWorktree
            var parked: String?
            if held { parked = try await freeMainCheckout(branch, base: draft.base, project: project) }
            if existing.matched && !held {
                worktree = .init(path: existing.path)
            } else {
                do {
                    worktree = try await api.request(Routes.WORKTREE, method: "POST", body:
                        WorktreeRequest(path: project.workspace, branch: branch, create: draft.createBranch, base: draft.base))
                } catch {
                    // The checkout has already moved and nothing undoes that, so the failure has to
                    // say it happened — otherwise the branch is gone from the main repo silently.
                    guard let parked else { throw error }
                    throw BackendError.operation("The main checkout was moved to \(parked), but the worktree could not be created: \(error.localizedDescription)")
                }
            }
        }
        guard !worktree.path.isEmpty else { throw BackendError.operation("Git did not return a worktree.") }
        if requireExactBranch {
            let verified: ResolvedWorktree = try await api.get(APIClient.query(Routes.WORKTREE,
                ["path": project.workspace, "branch": branch, "strict": "1"]))
            guard verified.matched, verified.branch == branch,
                  SessionRemovalPlan.path(verified.path) == SessionRemovalPlan.path(worktree.path) else {
                throw BackendError.operation("The checkout at \(worktree.path) does not match branch \(branch). It has been kept; resolve the branch or folder conflict before running this workflow.")
            }
        }
        let id = UUID().uuidString.lowercased()
        let session = WorkspaceSession(id: id, projectId: project.id, workspace: project.workspace, worktree: worktree.path,
            title: draft.title.isEmpty ? branch : draft.title, branch: branch,
            url: sourceURL.isEmpty ? "session:\(id)" : sourceURL, createdAt: ISO8601DateFormatter().string(from: Date()),
            pinned: false, kind: draft.kind, jiraKey: draft.jiraKey, cli: draft.agent.rawValue,
            sessionId: draft.agent == .claude ? UUID().uuidString.lowercased() : "")
        do { let _: OperationOK = try await api.request(Routes.TASKS, method: "POST", body: session) }
        catch { throw BackendError.operation("Worktree created at \(worktree.path), but the session could not be saved: \(error.localizedDescription). Use this branch again to recover it.") }
        return session
    }

    struct ResolvedWorktree: Decodable, Sendable {
        let path: String; let branch: String; let matched: Bool; let isWorktree: Bool
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool = false) async throws -> SessionDraft {
        guard let page = SessionPage.parse(raw) else { throw BackendError.operation("Enter a GitHub pull request or Jira issue URL, or type a branch name.") }
        var result = draft
        result.url = page.url; result.kind = page.kind; result.jiraKey = page.key
        result.reuseWorktree = nil
        if page.kind == "github" {
            struct PR: Decodable, Sendable { let repo: String; let title: String; let headRefName: String }
            let pr: PR?
            do { pr = try await api.get(APIClient.query(Routes.PR_LOOKUP, ["url": page.url]), timeout: 30) }
            catch is CancellationError { throw CancellationError() }
            catch { throw PullRequestBranchUnknown() }
            guard let pr, !pr.headRefName.isEmpty else { throw PullRequestBranchUnknown() }
            guard project.repo.isEmpty || project.repo.lowercased() == pr.repo.lowercased() else {
                throw BackendError.operation("This pull request belongs to \(pr.repo). Choose its project before creating the session.")
            }
            result.branch = pr.headRefName; result.title = pr.title; result.createBranch = false
        } else {
            struct Issue: Decodable, Sendable { let summary: String? }
            struct Search: Decodable, Sendable { let items: [Issue] }
            struct Query: Encodable, Sendable { let jql: String; let limit = 1 }
            let response: Search? = try? await api.request(Routes.JIRA_SEARCH, method: "POST", body: Query(jql: "key = \(page.key)"))
            let summary = response?.items.first?.summary ?? ""
            result.title = summary.isEmpty ? page.key : "\(page.key) \(summary)"
            result.branch = workflow ? WorkflowText.branch(key: page.key, summary: summary) : SessionPage.jiraBranch(key: page.key, summary: summary)
            result.createBranch = true
        }
        let match = page.kind == "jira" ? ["key": page.key] : ["branch": result.branch]
        let found: ResolvedWorktree = try await api.get(APIClient.query(Routes.WORKTREE,
            ["path": project.workspace, "strict": "1"].merging(match) { _, new in new }))
        // A checkout that is not a worktree is the main one. It cannot be reused, and it is NOT
        // freed here: this runs on every keystroke that parses as a URL, so moving a branch from it
        // would happen to someone who is still typing. `create` frees it, once Create is pressed.
        if found.matched && !found.isWorktree { return result }
        if found.matched {
            result.reuseWorktree = found.path; result.branch = found.branch; result.createBranch = false
        }
        return result
    }
    /// Git checks a branch out once, so the main checkout holding one leaves no room for the
    /// session's worktree. Feature branches live in worktrees here and the main checkout belongs on
    /// the session base, so parking it back there is what makes the room — there is nothing to ask.
    @discardableResult
    private func freeMainCheckout(_ branch: String, base selected: String, project: Project) async throws -> String {
        // "Branch from" decides where the checkout is parked; the session base only stands in for
        // the page flow, which creates without a sheet and so has nothing selected yet.
        let chosen = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = chosen.isEmpty ? try await references(project).sessionBase : chosen
        guard base != branch else {
            throw BackendError.operation("\(branch) is the branch this session forks from, so the main checkout cannot be moved off it. Choose a different \u{201C}Branch from\u{201D}.")
        }
        do { try await switchMainCheckout(to: base, project: project); return base }
        catch {
            throw BackendError.operation("\(branch) is checked out in the main repo, which could not be moved to \(base): \(error.localizedDescription)")
        }
    }

    func switchMainCheckout(to branch: String, project: Project) async throws {
        struct SwitchRequest: Encodable, Sendable { let path: String; let branch: String }
        let _: OperationOK = try await api.request(Routes.GIT_SWITCH, method: "POST",
            body: SwitchRequest(path: project.workspace, branch: branch))
    }

    func conversationExists(cli: String, id: String) async throws -> Bool {
        struct Found: Decodable, Sendable { let exists: Bool }
        let found: Found = try await api.get(APIClient.query(Routes.AGENT_CONVERSATION, ["cli": cli, "id": id]))
        return found.exists
    }
    func saveAgentID(_ id: String, session: WorkspaceSession) async throws {
        struct Payload: Encodable, Sendable { let sessionId: String }
        let _: OperationOK = try await api.request(Routes.task(session.id), method: "PATCH", body: Payload(sessionId: id))
    }
    func configureAgent(_ cli: WorkflowCLI, session: WorkspaceSession) async throws -> WorkspaceSession {
        var result = session
        if result.cli != cli.rawValue { result.cli = cli.rawValue; result.sessionId = "" }
        struct Payload: Encodable, Sendable { let cli: String; let sessionId: String }
        let _: OperationOK = try await api.request(Routes.task(session.id), method: "PATCH",
            body: Payload(cli: cli.rawValue, sessionId: result.sessionId ?? ""))
        return result
    }
    private func safeSessionURL(_ value: String) -> Bool {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
}
