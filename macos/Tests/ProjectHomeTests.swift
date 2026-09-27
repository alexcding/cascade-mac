import Foundation
import Testing

private struct PlanOperations: SessionCreating {
    var branches = ["main", "develop", "fix-login"]
    var pullRequestBranch: String? = "feature/pr"
    func references(_ project: Project) -> GitReferences {
        GitReferences(branches: branches.map { .init(name: $0) }, defaultBranch: "main")
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) throws -> SessionDraft {
        guard let branch = pullRequestBranch else { throw PullRequestBranchUnknown() }
        var result = draft
        result.url = raw; result.kind = "github"; result.branch = branch; result.createBranch = false
        return result
    }
    func create(project: Project, draft: SessionDraft) throws -> WorkspaceSession { throw CancellationError() }
    func switchMainCheckout(to branch: String, project: Project) {}
}

private let homeProject = Project(id: "home", name: "Home", repo: "o/r", color: nil, workspace: "/tmp/home")

@MainActor private func plan(_ text: String, agent: SessionAgent = .claude,
                             operations: PlanOperations = .init()) async throws -> ProjectSessionStart.Plan? {
    let request = ProjectSessionRequest(projectID: homeProject.id, text: text, agent: agent)
    guard case .planned(let plan) = try await ProjectSessionStart.plan(request, project: homeProject, operations: operations) else { return nil }
    return plan
}

@MainActor @Test func aTaskIsNamedFromItsWordsAndNeverReusesABranch() {
    #expect(ProjectSessionStart.branchName(for: "Fix the login crash on iOS 18!") == "fix-the-login-crash-on-ios-18")
    #expect(ProjectSessionStart.branchName(for: "Make the sidebar keep its scroll position when a session finishes") == "make-the-sidebar-keep-its-scroll")
    #expect(ProjectSessionStart.branchName(for: String(repeating: "a", count: 60)) == String(repeating: "a", count: 40))
    #expect(ProjectSessionStart.branchName(for: "!!! ???") == "session")
    #expect(ProjectSessionStart.uniqueBranch("fix-login", taken: ["fix-login", "fix-login-2"]) == "fix-login-3")
    #expect(ProjectSessionStart.uniqueBranch("new-work", taken: ["fix-login"]) == "new-work")
    #expect(ProjectSessionStart.title(for: "Fix login\nIt fails on the second try") == "Fix login")
}

@MainActor @Test func aTaskStartsANewBranchFromTheSessionBaseWithTheTextAsItsPrompt() async throws {
    let task = try #require(try await plan("  fix login\nIt fails on the second try  "))
    #expect(task.draft.branch == "fix-login-it-fails-on-the-second-try")
    #expect(task.draft.base == "develop" && task.draft.createBranch && task.draft.agent == .claude)
    #expect(task.draft.title == "fix login")
    #expect(task.prompt == "fix login\nIt fails on the second try")
    let taken = try #require(try await plan("Fix login"))
    #expect(taken.draft.branch == "fix-login-2")
}

@MainActor @Test func shellOnlyTreatsTheTextAsABranchAndALinkStartsOnItsPage() async throws {
    let shell = try #require(try await plan("feature/new thing", agent: .shell))
    #expect(shell.draft.branch == "feature/new-thing" && shell.draft.createBranch && shell.prompt == nil)
    let existing = try #require(try await plan("main", agent: .shell))
    #expect(existing.draft.branch == "main" && !existing.draft.createBranch)
    await #expect(throws: (any Error).self) { _ = try await plan("bad..name", agent: .shell) }

    let pull = try #require(try await plan("https://github.com/o/r/pull/7", agent: .codex))
    #expect(pull.draft.branch == "feature/pr" && pull.draft.kind == "github" && pull.prompt == nil && pull.draft.agent == .codex)
    var unknown = PlanOperations(); unknown.pullRequestBranch = nil
    let request = ProjectSessionRequest(projectID: homeProject.id, text: "https://github.com/o/r/pull/7", agent: .claude)
    guard case .needsBranch(let url) = try await ProjectSessionStart.plan(request, project: homeProject, operations: unknown) else {
        Issue.record("A pull request with no known branch should ask for it"); return
    }
    #expect(url == "https://github.com/o/r/pull/7")
    await #expect(throws: (any Error).self) { _ = try await plan("https://example.test/page") }
}

@Test func theFirstPromptRidesOnTheLaunchAsOneQuotedArgument() {
    let plain = SessionAgent.claude.command(sessionID: "id", fresh: true)
    let prompted = SessionAgent.claude.command(sessionID: "id", fresh: true, prompt: "Fix it's\nbroken")
    #expect(prompted == (plain ?? "") + " 'Fix it'\"'\"'s broken'")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "--help me") == "codex ' --help me'")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "  \n ") == "codex")
    #expect(SessionAgent.shell.command(sessionID: nil, prompt: "anything") == nil)
}

@MainActor private func homeModel(start: @escaping (ProjectSessionRequest) async throws -> Void = { _ in },
                                  project: Project = homeProject) -> ProjectPageViewModel {
    let editor = ProjectEditorViewModel(project: project, service: ProjectPageService(), chooseFolder: { nil })
    return ProjectPageViewModel(project: project, editor: editor,
                                composer: ProjectComposerModel(project: project, agent: .claude, start: start))
}

@MainActor @Test func aProjectOpensOnHomeAndItsTabsPickThePageUntilRetired() {
    let model = homeModel()
    #expect(model.section == .home && ProjectSection.allCases == [.home, .settings, .orchestration])
    model.selectSection(.settings)
    #expect(model.section == .settings)
    model.update(homeProject)
    #expect(model.section == .settings, "An update keeps the page the user is on")
    model.retire()
    model.selectSection(.orchestration)
    #expect(model.section == .settings)
}

@MainActor @Test func theComposerStartsWhatWasTypedAndKeepsItWhenStartingFails() async throws {
    var requests: [ProjectSessionRequest] = [], failure: String?
    let model = homeModel { request in
        requests.append(request)
        if let failure { throw BackendError.operation(failure) }
    }
    let composer = model.composer
    #expect(!composer.canStart)
    composer.text = "Fix login"; composer.select(.codex)
    await composer.submit()
    #expect(requests == [ProjectSessionRequest(projectID: "home", text: "Fix login", agent: .codex)] && composer.text.isEmpty)
    failure = "No worktree"
    composer.text = "Try again"
    await composer.submit()
    #expect(composer.text == "Try again" && composer.error == "No worktree" && !composer.busy)
    let folderless = homeModel(project: Project(id: "x", name: "X", repo: "", color: nil, workspace: ""))
    folderless.composer.text = "Anything"
    #expect(!folderless.composer.canStart)
    model.retire()
    await composer.submit()
    #expect(requests.count == 2)
}
