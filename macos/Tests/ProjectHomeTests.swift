import Foundation
import Testing

/// Records what Start asks of git: a PR link resolves to its branch unless `pullRequestBranch` is nil.
private actor StartOperations: SessionCreating {
    var branches = ["main", "develop", "fix-login"]
    var worktrees = ["fix-login-2"]
    var pullRequestBranch: String? = "feature/pr"
    var drafts: [SessionDraft] = []
    var failure: String?
    func fail(_ message: String?) { failure = message }
    func setUnknown() { pullRequestBranch = nil }
    func references(_ project: Project) -> GitReferences {
        GitReferences(branches: branches.map { .init(name: $0) }, defaultBranch: "main",
                      worktrees: worktrees.map { .init(branch: $0) })
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) throws -> SessionDraft {
        guard let branch = pullRequestBranch else { throw PullRequestBranchUnknown() }
        var result = draft
        result.url = raw; result.kind = "github"; result.branch = branch; result.createBranch = false
        return result
    }
    func create(project: Project, draft: SessionDraft) throws -> WorkspaceSession {
        if let failure { throw BackendError.operation(failure) }
        drafts.append(draft)
        return WorkspaceSession(id: "s\(drafts.count)", projectId: project.id, workspace: project.workspace, worktree: "/tmp/w",
                                title: draft.title, branch: draft.branch, url: draft.url, createdAt: nil, pinned: false)
    }
    func switchMainCheckout(to branch: String, project: Project) {}
}

private let homeProject = Project(id: "home", name: "Home", repo: "o/r", color: nil, workspace: "/tmp/home")

@MainActor private func composer(_ operations: StartOperations, agent: SessionAgent = .claude,
                                 project: Project = homeProject) async -> (ProjectComposerModel, () -> [(WorkspaceSession, String?)]) {
    let model = ProjectComposerModel(project: project, agent: agent, operations: operations)
    var created: [(WorkspaceSession, String?)] = []
    model.onAction = { if case .created(let session, let prompt) = $0 { created.append((session, prompt)) } }
    await model.loadReferences()
    return (model, { created })
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


@MainActor @Test func aTaskGetsANewBranchFromTheChosenBaseAndIsTheAgentsFirstPrompt() async throws {
    let operations = StartOperations()
    let (model, created) = await composer(operations)
    #expect(model.base == "develop" && model.branches.contains("main"))
    model.text = "  fix login\nIt fails on the second try  "
    #expect(model.hint?.text == "New branch fix-login-it-fails-on-the-second-try from develop; Claude Code starts with your text")
    model.base = "main"
    await model.submit()
    let draft = try #require(await operations.drafts.first)
    #expect(draft.branch == "fix-login-it-fails-on-the-second-try" && draft.base == "main" && draft.createBranch)
    #expect(draft.title == "fix login" && draft.agent == .claude && draft.url.isEmpty)
    #expect(created().first?.1 == "fix login\nIt fails on the second try" && model.text.isEmpty)
    // A name a branch or a worktree already has gets the next free one: a task is always new work.
    model.text = "Fix login two"
    #expect(model.hint?.text.hasPrefix("New branch fix-login-two from") == true)
    model.text = "fix login"
    await model.submit()
    #expect(await operations.drafts.last?.branch == "fix-login-3")
}

@MainActor @Test func anExistingBranchOpensAsItIsAndShellOnlyTakesABranchName() async throws {
    let operations = StartOperations()
    let (model, created) = await composer(operations)
    model.text = "develop"
    #expect(model.hint?.text == "Opens develop")
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.createBranch) } ?? ("", true) == ("develop", false))
    #expect(created().last.map { $0.1 == nil } == true, "An existing branch starts with no prompt")
    model.select(.shell)
    #expect(model.canStart && model.hint?.text == "New branch worktree1 from develop")
    model.text = "feature/new thing"
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.createBranch, $0.agent) } ?? ("", false, .claude) == ("feature/new-thing", true, .shell))
    model.text = "bad..name"
    await model.submit()
    #expect(model.hint?.isError == true && created().count == 2)
}

@MainActor @Test func aLinkStartsOnItsPageAndAnUnknownBranchIsAskedForInPlace() async throws {
    let operations = StartOperations()
    let (model, created) = await composer(operations, agent: .codex)
    model.text = "https://github.com/o/r/pull/7"
    #expect(await model.resolve())
    #expect(model.hint?.text == "Opens that pull request on feature/pr")
    await model.submit()
    let draft = try #require(await operations.drafts.last)
    #expect(draft.branch == "feature/pr" && draft.kind == "github" && draft.agent == .codex && created().last.map { $0.1 == nil } == true)
    model.text = "https://example.test/page"
    #expect(model.hint?.isError == true && !model.canStart)
    let unknown = StartOperations()
    await unknown.setUnknown()
    let (asking, _) = await composer(unknown)
    asking.text = "https://github.com/o/r/pull/9"
    _ = await asking.resolve()
    #expect(asking.showsPullRequestBranch && asking.hint?.text == "Name that pull request’s branch below")
}

@MainActor @Test func openingStartFromAPageFillsItInAndKeepsAPlainPageAsContext() async throws {
    let operations = StartOperations()
    let (model, _) = await composer(operations)
    let focus = model.focusRequest
    model.prepare(text: nil, contextURL: "https://docs.example.test/guide", agent: .codex)
    #expect(model.contextURL == "https://docs.example.test/guide" && model.agent == .codex && model.focusRequest == focus + 1)
    model.text = "Follow the guide"
    await model.submit()
    #expect(await operations.drafts.last?.url == "https://docs.example.test/guide" && model.contextURL == nil)
    // A PR or ticket link is what to start on, not context.
    model.prepare(text: "https://github.com/o/r/pull/7", contextURL: "https://github.com/o/r/pull/7", agent: nil)
    #expect(model.contextURL == nil && model.text == "https://github.com/o/r/pull/7" && model.agent == .codex)
    model.prepare(text: nil, contextURL: "https://docs.example.test/guide", agent: nil)
    model.clearContext()
    #expect(model.contextURL == nil)
}

@MainActor @Test func startKeepsTheTextWhenCreatingFailsAndNeedsAFolderAndAConnection() async throws {
    let operations = StartOperations()
    await operations.fail("No worktree")
    let (model, created) = await composer(operations)
    #expect(!model.canStart)
    model.text = "Try this"
    await model.submit()
    #expect(model.text == "Try this" && model.error == "No worktree" && created().isEmpty && !model.creating)
    let (folderless, _) = await composer(operations, project: Project(id: "x", name: "X", repo: "", color: nil, workspace: ""))
    folderless.text = "Anything"
    #expect(!folderless.canStart)
    model.connect(nil)
    #expect(!model.canStart)
    model.retire()
    model.prepare(text: "late", contextURL: nil, agent: nil)
    #expect(model.text == "Try this")
}

@Test func theFirstPromptRidesOnTheLaunchAsOneQuotedArgument() {
    let plain = SessionAgent.claude.command(sessionID: "id", fresh: true)
    let prompted = SessionAgent.claude.command(sessionID: "id", fresh: true, prompt: "Fix it's\nbroken")
    #expect(prompted == (plain ?? "") + " 'Fix it'\"'\"'s broken'")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "--help me") == "codex ' --help me'")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "  \n ") == "codex")
    #expect(SessionAgent.shell.command(sessionID: nil, prompt: "anything") == nil)
}


@MainActor private func pageModel() -> ProjectPageViewModel {
    let editor = ProjectEditorViewModel(project: homeProject, service: ProjectPageService(), chooseFolder: { nil })
    return ProjectPageViewModel(project: homeProject, editor: editor,
                                composer: ProjectComposerModel(project: homeProject, agent: .claude, operations: nil))
}

@MainActor @Test func aProjectOpensOnStartAndItsTabsPickThePageUntilRetired() {
    let model = pageModel()
    #expect(model.section == .start && ProjectSection.allCases == [.start, .orchestration, .settings])
    model.selectSection(.settings)
    #expect(model.section == .settings)
    model.update(homeProject)
    #expect(model.section == .settings, "An update keeps the page the user is on")
    model.start(text: "https://github.com/o/r/pull/7", agent: .shell)
    #expect(model.section == .start && model.composer.text == "https://github.com/o/r/pull/7" && model.composer.agent == .shell)
    model.retire()
    model.selectSection(.orchestration)
    #expect(model.section == .start)
}
