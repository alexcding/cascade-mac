import Foundation

struct OperationOK: Decodable, Sendable { let ok: Bool? }

enum SessionAgent: String, CaseIterable, Identifiable, Sendable {
    case shell = "", claude, codex
    var id: String { rawValue }
    var label: String { driver?.name ?? String(localized: "Shell only") }
    /// The chat's empty message field. A shell-only session has no chat.
    var chatPlaceholder: String { driver?.chatPlaceholder ?? "" }
    /// The CLI new sessions start in when none is chosen: the first the app offers.
    static var primary: SessionAgent { SessionAgent(rawValue: AgentDrivers.primary.cli) ?? .shell }

    /// Nil for a shell-only session, which has no agent to drive.
    var driver: (any AgentDriver)? { AgentDrivers.of(rawValue) }

    /// `prompt` is the new conversation's first message: both CLIs take it as their last argument.
    /// `forking` is a fork's source, as the backend gave it, and the fork's worktree: the conversation
    /// starts as a copy of the source's, working in that worktree.
    /// `launch` is the model and effort a new conversation starts on; a resumed one keeps its own.
    func command(sessionID: String?, fresh: Bool = false, statusLine: AgentStatusLine? = nil, prompt: String? = nil,
                 forking: (source: String, directory: String)? = nil, launch: AgentLaunchChoice? = nil) -> String? {
        guard let driver else { return nil }
        let command = if let forking {
            driver.forkCommand(from: forking.source, in: forking.directory, sessionID: sessionID, statusLine: statusLine)
        } else {
            driver.launchCommand(sessionID: sessionID, fresh: fresh, selection: launch?.model, effort: launch?.effort, statusLine: statusLine)
        }
        guard let prompt = Self.launchPrompt(prompt) else { return command }
        return command + " " + Self.quotePrompt(prompt)
    }
    static func quote(_ value: String) -> String { AgentDrivers.quote(value) }

    /// A first prompt as a launch argument, its line breaks kept, and never taken for an option —
    /// one that starts with a dash gets a space before it.
    static func launchPrompt(_ text: String?) -> String? {
        let prompt = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return prompt.hasPrefix("-") ? " " + prompt : prompt
    }

    /// A prompt as one line, for typing at an agent's own prompt, where Return sends it.
    static func promptLine(_ text: String?) -> String? {
        let line = (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.hasPrefix("-") ? " " + line : line
    }

    /// A prompt quoted for the shell as one argument. The command is typed into the terminal as a
    /// single line, so a prompt with line breaks or other control characters is written in the
    /// shell's `$'…'` quoting, which both zsh and bash turn back into the characters themselves.
    static func quotePrompt(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return quote(value) }
        var quoted = "$'"
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "'": quoted += "\\'"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f: quoted += String(format: "\\x%02x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "'"
    }
}

extension WorkspaceSession {
    /// The agent this session runs. A CLI this build does not know runs none.
    var agent: SessionAgent { SessionAgent(rawValue: cli ?? "") ?? .shell }
}

/// A pull request whose head branch nothing could tell us — the only resolution failure a
/// project's Start answers by asking for the branch. Every other failure is a real error.
struct PullRequestBranchUnknown: LocalizedError, Sendable {
    var errorDescription: String? { String(localized: "Could not look up this pull request’s branch.") }
}

struct GitReferences: Decodable, Sendable {
    /// `remote`: the branch is origin's and not checked out here yet; a session adopts it.
    struct Branch: Decodable, Sendable { let name: String; var current: Bool? = nil; var remote: Bool? = nil }
    struct Worktree: Decodable, Sendable { let branch: String?; var isMain: Bool? = nil; var path: String? = nil }
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
    /// The references after origin is fetched, for the branch picker opening, so a branch pushed
    /// from elsewhere is offered: nil when nothing was fetched (fetched within the last minute, or
    /// the fetch failed), since the list shown then already stands.
    func fetchedReferences(_ project: Project) async throws -> GitReferences?
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) async throws -> SessionDraft
    func create(project: Project, draft: SessionDraft) async throws -> WorkspaceSession
    /// Moves `project`'s main checkout onto `branch`, freeing the one it holds for a worktree.
    func switchMainCheckout(to branch: String, project: Project) async throws
}

protocol SessionServing: SessionCreating {
    func saveAgentID(_ id: String, session: WorkspaceSession) async throws
    func conversationExists(cli: String, id: String) async throws -> Bool
    func fork(_ session: WorkspaceSession) async throws -> ForkedSession
    /// Forgets what a fork's agent started from, once its own conversation exists.
    func clearFork(_ session: WorkspaceSession) async throws
}

/// A session the backend forked: its record, whose `forkFrom` its agent starts from, and what of
/// the source's uncommitted work did not come across.
struct ForkedSession: Decodable, Sendable {
    let task: WorkspaceSession
    let warning: String?
}

extension SessionCreating {
    func fetchedReferences(_ project: Project) async throws -> GitReferences? { try await references(project) }
}

struct SessionOperations: SessionServing {
    let api: APIClient
    func references(_ project: Project) async throws -> GitReferences {
        try await api.get(APIClient.query(Routes.GIT_REFS, ["path": project.workspace]))
    }
    func fetchedReferences(_ project: Project) async throws -> GitReferences? {
        struct Fetched: Decodable, Sendable { let fetched: Bool; var references: GitReferences? = nil }
        // The backend's fetch is capped at 20 seconds, and may wait for a picker's fetch of the
        // same checkout before it; the listing's own git calls follow.
        let answer: Fetched = try await api.get(APIClient.query(Routes.GIT_REFS, ["path": project.workspace, "fetch": "1"]), timeout: 75)
        return answer.fetched ? answer.references : nil
    }
    func create(project: Project, draft: SessionDraft) async throws -> WorkspaceSession {
        let branch = draft.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !project.workspace.isEmpty else { throw BackendError.operation(String(localized: "Choose a project workspace and branch.")) }
        guard sourceURL.isEmpty || safeSessionURL(sourceURL) else { throw BackendError.operation(String(localized: "The page address must use HTTP or HTTPS.")) }
        // One request: the backend resolves the branch's worktree, frees the main checkout when it
        // holds the branch, makes or reuses the worktree, and records the session last
        // (`crates/cascade-backend/src/sessions.rs`). Its answer is the record as the task list shows it.
        struct Request: Encodable, Sendable {
            let projectId: String; let branch: String; let createBranch: Bool; let base: String; let reuseWorktree: String?
            let url: String; let title: String; let kind: String; let jiraKey: String; let cli: String; let sessionId: String
        }
        return try await api.request(Routes.SESSIONS, method: "POST", body: Request(
            projectId: project.id, branch: branch, createBranch: draft.createBranch, base: draft.base, reuseWorktree: draft.reuseWorktree,
            url: sourceURL, title: draft.title, kind: draft.kind, jiraKey: draft.jiraKey, cli: draft.agent.rawValue,
            sessionId: draft.agent.driver?.namesConversationAtLaunch == true ? UUID().uuidString.lowercased() : ""))
    }

    struct ResolvedWorktree: Decodable, Sendable {
        let path: String; let branch: String; let matched: Bool; let isWorktree: Bool
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) async throws -> SessionDraft {
        guard let page = SessionPage.parse(raw) else { throw BackendError.operation(String(localized: "Enter a GitHub pull request or issue URL or a Jira issue URL, or type a branch name.")) }
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
                throw BackendError.operation(String(localized: "This pull request belongs to \(pr.repo). Choose its project before creating the session."))
            }
            result.branch = pr.headRefName; result.title = pr.title; result.createBranch = false
        } else if page.kind == "issue", let number = page.issueNumber, let repo = page.issueRepo {
            guard project.repo.isEmpty || project.repo.lowercased() == repo else {
                throw BackendError.operation(String(localized: "This issue belongs to \(repo). Choose its project before creating the session."))
            }
            struct Issue: Decodable, Sendable { let summary: String? }
            let issue: Issue? = try? await api.get(APIClient.query(Routes.ISSUE_LOOKUP, ["url": page.url]), timeout: 30)
            let title = issue?.summary ?? ""
            result.title = title.isEmpty ? "#\(number)" : "#\(number) \(title)"
            result.branch = SessionPage.issueBranch(number: number, title: title)
            result.createBranch = true
        } else {
            struct Issue: Decodable, Sendable { let summary: String? }
            struct Search: Decodable, Sendable { let items: [Issue] }
            struct Query: Encodable, Sendable { let jql: String; let limit = 1 }
            let response: Search? = try? await api.request(Routes.JIRA_SEARCH, method: "POST", body: Query(jql: "key = \(page.key)"))
            let summary = response?.items.first?.summary ?? ""
            result.title = summary.isEmpty ? page.key : "\(page.key) \(summary)"
            result.branch = SessionPage.jiraBranch(key: page.key, summary: summary)
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
    func fork(_ session: WorkspaceSession) async throws -> ForkedSession {
        struct Empty: Encodable, Sendable {}
        return try await api.request(Routes.taskFork(session.id), method: "POST", body: Empty())
    }
    func clearFork(_ session: WorkspaceSession) async throws {
        struct Payload: Encodable, Sendable { let forkFrom = "" }
        let _: OperationOK = try await api.request(Routes.task(session.id), method: "PATCH", body: Payload())
    }
    func saveAgentID(_ id: String, session: WorkspaceSession) async throws {
        struct Payload: Encodable, Sendable { let sessionId: String }
        let _: OperationOK = try await api.request(Routes.task(session.id), method: "PATCH", body: Payload(sessionId: id))
    }
    private func safeSessionURL(_ value: String) -> Bool {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
}
