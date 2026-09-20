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
    let model = NewSessionViewModel(project: project, operations: operations)
    model.onAction = { if case .created(let session) = $0 { created = session } }
    await model.loadReferences()
    #expect(model.title == "New session on Fixture")
    #expect(model.placeholder == "worktree1" && model.draft.base == "main" && model.input.isEmpty)
    model.draft.agent = .shell
    model.input = "https://github.com/fixture/repo/pull/42"
    await model.create()
    #expect(model.completed)
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
    let model = NewSessionViewModel(project: project, operations: SessionOperations(api: api))
    await model.loadReferences()
    #expect(model.fieldHint.text == NewSessionViewModel.hint && !model.fieldHint.isError)
    model.input = "https://example.com/not-a-page"
    #expect(model.fieldHint.isError && !model.canCreate)
    model.input = "https://jira.test/browse/RECORD-12"
    #expect(await model.resolve())
    #expect(model.fieldHint.text == "Opens RECORD-12 Native sidebar — branch RECORD-12-existing")
    #expect(model.worktreeHint == "Runs in existing on RECORD-12-existing")
    model.input = "bad..name"
    #expect(model.resolved == nil && model.worktreeHint == nil)
    await model.create()
    #expect(model.fieldHint.isError && !model.completed)
    #expect(NewSessionViewModel.branchNameError("feature/ok-1") == nil)
    #expect(NewSessionViewModel.branchNameError("feature/.hidden") != nil)
    #expect(NewSessionViewModel.branchNameError("has space") != nil)
}

@Test func agentCommandsResumeExactIDsAndQuoteShellMetacharacters() {
    #expect(SessionAgent.shell.command(sessionID: nil) == nil)
    #expect(SessionAgent.claude.command(sessionID: "saved") == "claude --resume 'saved'")
    #expect(SessionAgent.claude.command(sessionID: "new", fresh: true) == "claude --session-id 'new'")
    #expect(SessionAgent.codex.command(sessionID: "saved") == "codex resume 'saved'")
    #expect(SessionAgent.codex.command(sessionID: "") == "codex")
    #expect(SessionAgent.quote("a'$(touch /tmp/no);b") == "'a'\"'\"'$(touch /tmp/no);b'")
}

@Test func workflowPagePreparationUsesWorkflowBranchAndReusesResolvedWorktrees() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionHTTPFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    var project = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
    project.jiraProjectKey = "RECORD"
    let service = APIWorkflowPagePreparation(operations: SessionOperations(api: api))
    let fresh = try #require(WorkflowPageTarget.resolve(url: "https://jira.test/browse/RECORD-13", projects: [project]))
    let created = try await service.prepare(fresh, project: project)
    #expect(created.branch == "feature/record-13-native-sidebar")
    #expect(created.cli == "" && created.sessionId == "")
    #expect(created.jiraKey == "RECORD-13" && fresh.matches(created))
    let existing = try #require(WorkflowPageTarget.resolve(url: "https://jira.test/browse/RECORD-12", projects: [project]))
    let reused = try await service.prepare(existing, project: project)
    #expect(reused.branch == "RECORD-12-existing" && reused.worktree == "/tmp/existing")
    let pull = try #require(WorkflowPageTarget.resolve(url: "https://github.com/fixture/repo/pull/42/files", projects: [project]))
    let pr = try await service.prepare(pull, project: project)
    #expect(pr.branch == "feature/native" && pr.kind == "github")
    #expect(pull.matches(pr))
    let canonical = try #require(WorkflowPageTarget.resolve(url: "https://github.com/FIXTURE/repo/pull/42?diff=split", projects: [project]))
    #expect(canonical.identity == pull.identity && canonical.matches(pr))
    #expect(WorkflowPageTarget.resolve(url: "https://github.com/elsewhere/repo/pull/42", projects: [project]) == nil)
    #expect(WorkflowPageTarget.resolve(url: fresh.page.url, projects: [project, project]) == nil)
}

@MainActor @Test func workflowPagePromotionRetainsLiveContextObjectsAndMergesExistingContext() throws {
    let viewer = ViewerStore()
    let pageID = "tab:https://jira.test/browse/REC-1"
    let context = viewer.select(id: pageID, url: "", title: "Issue")
    let document = try #require(context.openFile("/tmp/Workflow.swift"))
    let selection = context.activeID
    try viewer.promoteContext(from: pageID, to: "task:prepared")
    #expect(viewer.contexts[pageID] == nil)
    #expect(viewer.active === context && context.id == "task:prepared")
    #expect(context.documents.first === document && context.activeID == selection)
    let other = viewer.select(id: "task:other", url: "", title: "Other")
    let otherDocument = try #require(other.openFile("/tmp/Other.swift"))
    _ = viewer.select(id: "task:prepared", url: "", title: "")
    try viewer.promoteContext(from: "task:prepared", to: "task:other")
    #expect(viewer.contexts["task:prepared"] == nil && viewer.active === other)
    #expect(other.documents.first === otherDocument && other.documents.last === document)
    #expect(other.activeDocument === document && context.documents.isEmpty)
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
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool) throws -> SessionDraft {
        resolutions += 1
        if let resolutionError { throw resolutionError }
        return draft
    }
    private(set) var movedMainCheckoutTo: String?
    /// Moving the checkout frees the branch, so what failed on it resolves the next time.
    func switchMainCheckout(to branch: String, project: Project) { movedMainCheckoutTo = branch; resolutionError = nil }
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool) -> WorkspaceSession {
        creations += 1
        return WorkspaceSession(id: "created", projectId: project.id, workspace: project.workspace, worktree: "/tmp/w",
                                title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false)
    }
}

private let scriptedProject = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")

@MainActor @Test(.timeLimit(.minutes(1))) func sessionCreateRetriesAFailedTicketLookupAndKeepsItsError() async {
    let service = ScriptedSessionService(resolutionError: BackendError.operation("Worktree lookup failed"))
    let model = NewSessionViewModel(project: scriptedProject, operations: service)
    model.input = "https://jira.test/browse/RECORD-12"
    #expect(await model.resolve() == false)
    #expect(model.error == "Worktree lookup failed" && model.canCreate && !model.showsPullRequestBranch)
    await model.create()
    await model.create()
    #expect(model.error == "Worktree lookup failed" && !model.completed)
    #expect(await service.resolutions == 3) // each Create looks the page up again
    #expect(await service.creations == 0)
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionAsksForThePullRequestBranchOnlyWhenTheBranchIsUnknown() async {
    let mismatch = ScriptedSessionService(resolutionError: BackendError.operation("This pull request belongs to other/repo."))
    let wrongProject = NewSessionViewModel(project: scriptedProject, operations: mismatch)
    wrongProject.input = "https://github.com/other/repo/pull/7"
    _ = await wrongProject.resolve()
    #expect(!wrongProject.showsPullRequestBranch && wrongProject.error == "This pull request belongs to other/repo.")
    await wrongProject.create()
    #expect(await mismatch.creations == 0)

    let unknown = ScriptedSessionService(resolutionError: PullRequestBranchUnknown())
    let model = NewSessionViewModel(project: scriptedProject, operations: unknown)
    var created: WorkspaceSession?
    model.onAction = { if case .created(let session) = $0 { created = session } }
    model.input = "https://github.com/fixture/repo/pull/42"
    _ = await model.resolve()
    #expect(model.showsPullRequestBranch && model.error == nil)
    await model.create()
    #expect(model.fieldHint.isError && created == nil)
    model.pullRequestBranch = "feature/known"
    await model.create()
    #expect(created?.branch == "feature/known" && created?.url == "https://github.com/fixture/repo/pull/42")
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionBranchListErrorSurvivesEditingTheField() async {
    let model = NewSessionViewModel(project: scriptedProject, operations: ScriptedSessionService(referencesFail: true))
    await model.loadReferences()
    #expect(model.referenceError == "Could not read refs" && model.error == nil)
    model.input = "feature/x"
    #expect(model.referenceError == "Could not read refs")
}

private final class ExistingCheckoutFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var posts: [String] = []
    nonisolated(unsafe) static var switched: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let branch = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "branch" }?.value ?? ""
        let body: String
        switch (url.path, request.httpMethod ?? "GET") {
        case (Routes.WORKTREE, "POST"):
            Self.lock.withLock { Self.posts.append(url.path) }
            body = #"{"path":"/tmp/fixture.worktrees/fresh"}"#
        case (Routes.WORKTREE, _) where branch == "reuse-me":
            body = #"{"matched":true,"isWorktree":true,"branch":"reuse-me","path":"/tmp/fixture.worktrees/reuse-me"}"#
        case (Routes.WORKTREE, _) where branch == "main" || url.query?.contains("key=MAIN-1") == true:
            body = #"{"matched":true,"isWorktree":false,"branch":"main","path":"/tmp/fixture"}"#
        // The main checkout is parked on this one, so it is matched but is not a worktree.
        case (Routes.WORKTREE, _) where branch == "develop":
            body = #"{"matched":true,"isWorktree":false,"branch":"develop","path":"/tmp/fixture"}"#
        case (Routes.WORKTREE, _) where branch == "held":
            body = #"{"matched":true,"isWorktree":false,"branch":"held","path":"/tmp/fixture"}"#
        case (Routes.GIT_SWITCH, "POST"):
            Self.lock.withLock { Self.switched.append(Self.bodyBranch(self.request)) }
            body = #"{"ok":true}"#
        case (Routes.GIT_REFS, _):
            body = #"{"branches":[{"name":"main"},{"name":"develop"}],"defaultBranch":"main"}"#
        case (Routes.WORKTREE, _):
            body = #"{"matched":false,"isWorktree":false,"branch":"","path":""}"#
        default: body = #"{"ok":true}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// URLProtocol hands a POST body back as a stream, so the recorded branch has to be read out.
    static func bodyBranch(_ request: URLRequest) -> String {
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
        struct Body: Decodable { let branch: String }
        return (try? JSONDecoder().decode(Body.self, from: data))?.branch ?? ""
    }
}

@Test func sessionCreationReusesAnExistingCheckoutAndFreesTheMainCheckout() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExistingCheckoutFixture.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    let operations = SessionOperations(api: api)
    let project = Project(id: "fixture", name: "Fixture", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture")
    func draft(_ branch: String, base: String = "") -> SessionDraft {
        var d = SessionDraft(); d.branch = branch; d.base = base; d.agent = .shell; return d
    }
    ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.posts = []; ExistingCheckoutFixture.switched = [] }

    // An existing WORKTREE is adopted as it stands: the session is new, the checkout is not.
    let reused = try await operations.create(project: project, draft: draft("reuse-me"), requireExactBranch: false)
    #expect(reused.worktree == "/tmp/fixture.worktrees/reuse-me")
    #expect(ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.posts.isEmpty })

    // A branch the MAIN checkout holds is different: every task branch belongs in a worktree of its
    // own, so the main checkout is parked on the selected base and the branch then gets one.
    var held = draft("held", base: "develop")
    held.createBranch = false
    let freed = try await operations.create(project: project, draft: held, requireExactBranch: false)
    #expect(ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.switched } == ["develop"])
    // Never the main repo's own path, which is what `matched` pointed at.
    #expect(freed.worktree == "/tmp/fixture.worktrees/fresh")
    #expect(ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.posts.count } == 1)

    // Nothing selected — the page flow creates without a sheet — falls back to the session base.
    _ = try await operations.create(project: project, draft: draft("main"), requireExactBranch: false)
    #expect(ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.switched.last } == "develop")

    // Resolving is a LOOKUP. It runs on every keystroke that parses as a URL, so it must never
    // move a checkout — it only declines to reuse the main one.
    let before = ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.switched.count }
    let resolved = try await operations.resolvePage("https://jira.test/browse/MAIN-1", project: project, draft: SessionDraft())
    #expect(resolved.reuseWorktree == nil)
    #expect(ExistingCheckoutFixture.lock.withLock { ExistingCheckoutFixture.switched.count } == before)

    // The one case with nowhere to park it: the branch IS the base this session forks from.
    await #expect(throws: BackendError.self) {
        _ = try await operations.create(project: project, draft: draft("develop", base: "develop"), requireExactBranch: false)
    }

    let fresh = try await operations.create(project: project, draft: draft("fresh"), requireExactBranch: false)
    #expect(fresh.worktree == "/tmp/fixture.worktrees/fresh")
}

private actor PageStartService: SessionCreating {
    let resolution: Result<SessionDraft, any Error>
    var baseRequests = 0
    private(set) var createdDraft: SessionDraft?
    init(_ resolution: Result<SessionDraft, any Error>) { self.resolution = resolution }
    func references(_ project: Project) -> GitReferences {
        baseRequests += 1
        return GitReferences(branches: [.init(name: "main"), .init(name: "develop")], defaultBranch: "main")
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft, workflow: Bool) throws -> SessionDraft {
        var result = try resolution.get(); result.agent = draft.agent; return result
    }
    private(set) var movedMainCheckoutTo: String?
    func switchMainCheckout(to branch: String, project: Project) { movedMainCheckoutTo = branch }
    func create(project: Project, draft: SessionDraft, requireExactBranch: Bool) -> WorkspaceSession {
        createdDraft = draft
        return WorkspaceSession(id: "page", projectId: project.id, workspace: project.workspace, worktree: draft.reuseWorktree ?? "/tmp/new",
                                title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false)
    }
}

@Test func pageSessionStartCreatesAtOnceFallsBackToTheSheetAndReportsFailures() async {
    var ticket = SessionDraft(); ticket.url = "https://jira.test/browse/REC-1"; ticket.kind = "jira"; ticket.branch = "REC-1-fix"; ticket.createBranch = true
    let fresh = PageSessionStart.self
    let newBranch = PageStartService(.success(ticket))
    guard case .created(let session) = await fresh.run(url: ticket.url, project: scriptedProject, agent: .codex, operations: newBranch) else {
        Issue.record("A ticket page should create its session at once"); return
    }
    #expect(session.branch == "REC-1-fix")
    let createdDraft = await newBranch.createdDraft
    #expect(createdDraft?.base == "develop" && createdDraft?.agent == .codex)

    var reused = ticket; reused.reuseWorktree = "/tmp/existing"; reused.createBranch = false
    let existing = PageStartService(.success(reused))
    guard case .created(let onExisting) = await fresh.run(url: ticket.url, project: scriptedProject, agent: .shell, operations: existing) else {
        Issue.record("An existing checkout should be reused"); return
    }
    let baseRequests = await existing.baseRequests
    #expect(onExisting.worktree == "/tmp/existing" && baseRequests == 0)

    guard case .needsBranch = await fresh.run(url: "https://github.com/fixture/repo/pull/1", project: scriptedProject, agent: .shell,
                                              operations: PageStartService(.failure(PullRequestBranchUnknown()))) else {
        Issue.record("An unknown PR branch should fall back to the sheet"); return
    }
    guard case .failed(let message) = await fresh.run(url: ticket.url, project: scriptedProject, agent: .shell,
                                                      operations: PageStartService(.failure(BackendError.operation("feature/x is checked out in the main repo — switch it away there first.")))) else {
        Issue.record("Other failures should be reported"); return
    }
    #expect(message.contains("checked out in the main repo"))
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
