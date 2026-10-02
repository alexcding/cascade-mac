import Foundation
import Testing

@Test func sessionURLsAndJiraBranchNamesMatchExistingConventions() {
    #expect(SessionPage.parse("https://github.com/owner/repo/pull/42/files")?.kind == "github")
    #expect(SessionPage.parse("https://other.test/owner/repo/pull/42") == nil)
    #expect(SessionPage.parse("https://github.com/owner/repo/pull/-1") == nil)
    #expect(SessionPage.parse("https://jira.test/browse/record-123")?.key == "RECORD-123")
    #expect(SessionPage.parse("https://user:secret@jira.test/browse/RECORD-123") == nil)
    #expect(SessionPage.jiraBranch(key: "RECORD-123", summary: "Fix iOS: Sidebar / navigation") == "RECORD-123-fix-ios-sidebar-navigation")
    #expect(SessionPage.jiraBranch(key: "RECORD-123", summary: "") == "RECORD-123")
}

private final class SessionHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        switch path {
        case Routes.GIT_REFS: body = #"{"branches":[{"name":"main"}],"defaultBranch":"main"}"#
        case Routes.PR_LOOKUP: body = #"{"repo":"fixture/repo","title":"Native sidebar","headRefName":"feature/native"}"#
        case Routes.JIRA_SEARCH: body = #"{"items":[{"summary":"Native sidebar"}]}"#
        case Routes.WORKTREE:
            let query = request.url!.query ?? ""
            if request.httpMethod == "POST" { body = #"{"path":"/tmp/fixture.worktrees/native"}"# }
            else if query.contains("RECORD-12") { body = #"{"matched":true,"isWorktree":true,"branch":"RECORD-12-existing","path":"/tmp/existing"}"# }
            else if let branch = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "branch" })?.value {
                body = String(decoding: try! JSONSerialization.data(withJSONObject: ["matched": true, "isWorktree": true, "branch": branch, "path": "/tmp/fixture.worktrees/native"]), as: UTF8.self)
            }
            else { body = #"{"matched":false,"isWorktree":false,"branch":"","path":""}"# }
        case Routes.SESSIONS:
            body = #"{"id":"created","projectId":"fixture","workspace":"/tmp/fixture","worktree":"/tmp/fixture.worktrees/native","title":"Native sidebar","branch":"feature/native","url":"https://github.com/fixture/repo/pull/42","pinned":false,"kind":"github","cli":"claude","sessionId":""}"#
        default: body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func sessionModelResolvesPRBeforeCreationAndReusesTicketWorktrees() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
    let operations = SessionOperations(api: api)
    var created: WorkspaceSession?
    let model = ProjectComposerModel(project: project, agent: .claude, operations: operations)
    model.onAction = { if case .created(let session, _) = $0 { created = session } }
    await model.loadReferences()
    #expect(model.base == "main" && model.text.isEmpty && model.hint == nil)
    model.select(.shell)
    model.text = "https://github.com/fixture/repo/pull/42"
    await model.submit()
    #expect(created != nil && model.text.isEmpty)
    #expect(created?.branch == "feature/native" && created?.kind == "github")
    #expect(created?.url == "https://github.com/fixture/repo/pull/42" && created?.projectId == project.id)
    let jira = try await operations.resolvePage("https://jira.test/browse/RECORD-12", project: project, draft: SessionDraft())
    #expect(jira.branch == "RECORD-12-existing" && jira.reuseWorktree == "/tmp/existing" && !jira.createBranch)
    #expect(jira.jiraKey == "RECORD-12" && jira.title == "RECORD-12 Native sidebar")
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionFieldReadsBranchOrAddressAndValidatesBranchNames() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let project = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
    let model = ProjectComposerModel(project: project, agent: .shell, operations: SessionOperations(api: api))
    var created = 0
    model.onAction = { _ in created += 1 }
    await model.loadReferences()
    #expect(model.hint == nil && !model.canStart, "Nothing typed, nothing to say or start")
    model.text = "https://example.com/not-a-page"
    #expect(model.hint?.isError == true && !model.canStart)
    model.text = "https://jira.test/browse/RECORD-12"
    #expect(await model.resolve())
    #expect(model.hint?.text == "Opens RECORD-12 Native sidebar in existing on RECORD-12-existing")
    model.text = "bad..name"
    #expect(model.resolved == nil && model.hint == nil)
    await model.submit()
    #expect(model.hint?.isError == true && created == 0)
    #expect(ProjectSessionStart.branchNameError("feature/ok-1") == nil)
    #expect(ProjectSessionStart.branchNameError("feature/.hidden") != nil)
    #expect(ProjectSessionStart.branchNameError("has space") != nil)
}

@Test func agentCommandsResumeExactIDsAndQuoteShellMetacharacters() {
    #expect(SessionAgent.shell.command(sessionID: nil) == nil)
    #expect(SessionAgent.claude.command(sessionID: "saved") == "claude --resume 'saved'")
    #expect(SessionAgent.claude.command(sessionID: "new", fresh: true) == "claude --session-id 'new'")
    #expect(SessionAgent.codex.command(sessionID: "saved") == "codex resume 'saved'")
    #expect(SessionAgent.codex.command(sessionID: "") == "codex")
    #expect(SessionAgent.quote("a'$(touch /tmp/no);b") == "'a'\"'\"'$(touch /tmp/no);b'")
}


private actor ScriptedSessionService: SessionCreating {
    var resolutionError: (any Error)?
    var referencesFail = false
    var resolutions = 0, creations = 0
    init(resolutionError: (any Error)? = nil, referencesFail: Bool = false) {
        self.resolutionError = resolutionError; self.referencesFail = referencesFail
    }
    func references(_ project: Project) throws -> GitReferences {
        if referencesFail { throw BackendError.operation("Could not read refs") }
        return GitReferences(branches: [.init(name: "main")], defaultBranch: "main")
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) throws -> SessionDraft {
        resolutions += 1
        if let resolutionError { throw resolutionError }
        return draft
    }
    private(set) var movedMainCheckoutTo: String?
    /// Moving the checkout frees the branch, so what failed on it resolves the next time.
    func switchMainCheckout(to branch: String, project: Project) { movedMainCheckoutTo = branch; resolutionError = nil }
    func create(project: Project, draft: SessionDraft) -> WorkspaceSession {
        creations += 1
        return WorkspaceSession(id: "created", projectId: project.id, workspace: project.workspace, worktree: "/tmp/w",
                                title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false)
    }
}

private let scriptedProject = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")

@MainActor @Test(.timeLimit(.minutes(1))) func sessionCreateRetriesAFailedTicketLookupAndKeepsItsError() async {
    let service = ScriptedSessionService(resolutionError: BackendError.operation("Worktree lookup failed"))
    let model = ProjectComposerModel(project: scriptedProject, agent: .claude, operations: service)
    model.text = "https://jira.test/browse/RECORD-12"
    #expect(await model.resolve() == false)
    #expect(model.error == "Worktree lookup failed" && model.canStart && !model.showsPullRequestBranch)
    await model.submit()
    await model.submit()
    #expect(model.error == "Worktree lookup failed" && !model.text.isEmpty)
    #expect(await service.resolutions == 3) // each Create looks the page up again
    #expect(await service.creations == 0)
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionAsksForThePullRequestBranchOnlyWhenTheBranchIsUnknown() async {
    let mismatch = ScriptedSessionService(resolutionError: BackendError.operation("This pull request belongs to other/repo."))
    let wrongProject = ProjectComposerModel(project: scriptedProject, agent: .claude, operations: mismatch)
    wrongProject.text = "https://github.com/other/repo/pull/7"
    _ = await wrongProject.resolve()
    #expect(!wrongProject.showsPullRequestBranch && wrongProject.error == "This pull request belongs to other/repo.")
    await wrongProject.submit()
    #expect(await mismatch.creations == 0)

    let unknown = ScriptedSessionService(resolutionError: PullRequestBranchUnknown())
    let model = ProjectComposerModel(project: scriptedProject, agent: .claude, operations: unknown)
    var created: WorkspaceSession?, prompt: String??
    model.onAction = { if case .created(let session, let first) = $0 { created = session; prompt = first } }
    model.text = "https://github.com/fixture/repo/pull/42"
    _ = await model.resolve()
    #expect(model.showsPullRequestBranch && model.error == nil)
    await model.submit()
    #expect(model.hint?.isError == true && created == nil)
    model.pullRequestBranch = "feature/known"
    await model.submit()
    #expect(created?.branch == "feature/known" && created?.url == "https://github.com/fixture/repo/pull/42")
    #expect(prompt == .some(nil), "A link starts on its page, with no prompt")
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionBranchListErrorSurvivesEditingTheField() async {
    let model = ProjectComposerModel(project: scriptedProject, agent: .shell, operations: ScriptedSessionService(referencesFail: true))
    await model.loadReferences()
    #expect(model.referenceError == "Could not read refs" && model.error == nil)
    model.text = "feature/x"
    #expect(model.referenceError == "Could not read refs")
}

/// Records what `create` sends and answers with a record built from it; a branch named `refused`
/// is answered as the backend refuses a checkout it cannot free.
private final class SessionRequestFixture: URLProtocol, @unchecked Sendable {
    struct Sent: Decodable {
        let projectId: String; let branch: String; let createBranch: Bool; let base: String; let reuseWorktree: String?
        let url: String; let title: String; let kind: String; let cli: String; let sessionId: String
    }
    nonisolated(unsafe) static var sent: [Sent] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        let body: String
        switch (url.path, request.httpMethod ?? "GET") {
        case (Routes.SESSIONS, "POST"):
            let sent = try! JSONDecoder().decode(Sent.self, from: Self.body(request))
            Self.lock.withLock { Self.sent.append(sent) }
            if sent.branch == "refused" {
                status = 409
                body = #"{"error":"refused is the branch this session forks from, so the main checkout cannot be moved off it."}"#
            } else {
                body = #"{"id":"made","projectId":"\#(sent.projectId)","workspace":"/tmp/fixture","worktree":"/tmp/fixture.worktrees/\#(sent.branch)","title":"\#(sent.title.isEmpty ? sent.branch : sent.title)","branch":"\#(sent.branch)","url":"session:made","pinned":false,"kind":"\#(sent.kind)","cli":"\#(sent.cli)","sessionId":"\#(sent.sessionId)"}"#
            }
        case (Routes.WORKTREE, _) where url.query?.contains("key=MAIN-1") == true:
            body = #"{"matched":true,"isWorktree":false,"branch":"main","path":"/tmp/fixture"}"#
        case (Routes.GIT_REFS, _):
            body = #"{"branches":[{"name":"main"},{"name":"develop"}],"defaultBranch":"main"}"#
        case (Routes.WORKTREE, _):
            body = #"{"matched":false,"isWorktree":false,"branch":"","path":""}"#
        default: body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// URLProtocol hands a POST body back as a stream, so it has to be read out.
    static func body(_ request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[..<read])
            }
        }
        return data
    }
}

@Test func sessionCreationSendsOneRequestWithTheDraftAndDecodesTheRecord() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionRequestFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let operations = SessionOperations(api: api)
    let project = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
    func draft(_ branch: String, base: String = "", reuse: String? = nil) -> SessionDraft {
        var d = SessionDraft(); d.branch = branch; d.base = base; d.reuseWorktree = reuse; d.agent = .shell; return d
    }
    SessionRequestFixture.lock.withLock { SessionRequestFixture.sent = [] }

    // Every decision the backend needs travels in the one request; the record comes back whole.
    let reused = try await operations.create(project: project, draft: draft("reuse-me", reuse: "/tmp/fixture.worktrees/reuse-me"))
    #expect(reused.worktree == "/tmp/fixture.worktrees/reuse-me" && reused.title == "reuse-me" && reused.projectId == "fixture")
    var held = draft("held", base: "develop")
    held.createBranch = false; held.title = "Held work"
    let freed = try await operations.create(project: project, draft: held)
    #expect(freed.title == "Held work" && freed.branch == "held")
    let sent = SessionRequestFixture.lock.withLock { SessionRequestFixture.sent }
    #expect(sent.map(\.branch) == ["reuse-me", "held"])
    #expect(sent[0].reuseWorktree == "/tmp/fixture.worktrees/reuse-me" && sent[0].createBranch)
    // A shell-only session names no CLI, so the backend stores an empty one.
    #expect(sent[1].reuseWorktree == nil && sent[1].base == "develop" && !sent[1].createBranch && sent[1].cli == SessionAgent.shell.rawValue)

    // A refusal is the backend's words, as an error.
    await #expect(throws: BackendError.self) {
        _ = try await operations.create(project: project, draft: draft("refused", base: "refused"))
    }

    // Resolving is a LOOKUP. It runs on every keystroke that parses as a URL, so it must never
    // create anything: it only declines to reuse the main checkout.
    let before = SessionRequestFixture.lock.withLock { SessionRequestFixture.sent.count }
    let resolved = try await operations.resolvePage("https://jira.test/browse/MAIN-1", project: project, draft: SessionDraft())
    #expect(resolved.reuseWorktree == nil)
    #expect(SessionRequestFixture.lock.withLock { SessionRequestFixture.sent.count } == before)

    // Nothing to send without a branch or a workspace.
    await #expect(throws: BackendError.self) { _ = try await operations.create(project: project, draft: draft("")) }
}

@MainActor @Test func onlyPullRequestAndTicketPagesWithAProjectOfferASession() {
    let widgets = Project(id: "w", name: "Widgets", repo: "Acme/Widgets", color: nil, workspace: "/tmp/widgets", jiraProjectKey: "WID, OPS")
    let unconfigured = Project(id: "u", name: "No workspace", repo: "acme/other", color: nil, workspace: "", jiraProjectKey: "OTH")
    let projects = [widgets, unconfigured]
    #expect(AppViewModel.pageProject("https://github.com/acme/widgets/pull/7", in: projects)?.id == "w")
    #expect(AppViewModel.pageProject("https://acme.atlassian.net/browse/OPS-12", in: projects)?.id == "w")
    // No project claims it, or the claiming project has no local workspace.
    #expect(AppViewModel.pageProject("https://github.com/someone/else/pull/3", in: projects) == nil)
    #expect(AppViewModel.pageProject("https://github.com/acme/other/pull/3", in: projects) == nil)
    #expect(AppViewModel.pageProject("https://acme.atlassian.net/browse/OTH-1", in: projects) == nil)
    // Not a pull request or ticket page, even with a single project.
    #expect(AppViewModel.pageProject("https://github.com/acme/widgets", in: [widgets]) == nil)
    #expect(AppViewModel.pageProject("https://example.org/plain", in: [widgets]) == nil)
}
