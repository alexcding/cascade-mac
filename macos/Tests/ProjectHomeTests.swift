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
    func setPullRequestBranch(_ branch: String) { pullRequestBranch = branch }
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
    model.onAction = { if case .created(let session, let prompt, _) = $0 { created.append((session, prompt)) } }
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
    #expect(model.hint == nil, "Plain text needs no explaining")
    model.base = "main"
    await model.submit()
    let draft = try #require(await operations.drafts.first)
    #expect(draft.branch == "fix-login-it-fails-on-the-second-try" && draft.base == "main" && draft.createBranch)
    #expect(draft.title == "fix login" && draft.agent == .claude && draft.url.isEmpty)
    #expect(created().first?.1 == "fix login\nIt fails on the second try" && model.text.isEmpty)
    // A name a branch or a worktree already has gets the next free one: a task is always new work.
    model.text = "fix login"
    await model.submit()
    #expect(await operations.drafts.last?.branch == "fix-login-3")
}

@MainActor @Test func anExistingBranchOpensAsItIsAndShellOnlyTakesABranchName() async throws {
    let operations = StartOperations()
    let (model, created) = await composer(operations)
    model.text = "develop"
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.createBranch) } ?? ("", true) == ("develop", false))
    #expect(created().last.map { $0.1 == nil } == true, "An existing branch starts with no prompt")
    model.select(.shell)
    #expect(!model.canStart && model.hint == nil, "Shell only needs a branch name too")
    model.text = "feature/new thing"
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.createBranch, $0.agent) } ?? ("", false, .claude) == ("feature/new-thing", true, .shell))
    model.text = "bad..name"
    await model.submit()
    #expect(model.hint?.isError == true && created().count == 2)
}

@MainActor @Test func existingBranchWorksOnTheChosenBranchWithTheTaskAsItsPrompt() async throws {
    let operations = StartOperations()
    let (model, created) = await composer(operations)
    model.branchMode = .existing
    #expect(!model.canStart && model.hint?.text == "Choose the branch to work on",
            "The base — usually the main checkout's branch — is never taken for the branch to work on")
    model.choose("fix-login")
    #expect(model.base == "develop", "Picking the branch to work on leaves the base alone")
    #expect(model.canStart, "The chosen branch is enough to start on")
    #expect(model.hint?.text == "Checks out fix-login in a new worktree")
    model.text = "Finish the login fix"
    await model.submit()
    let draft = try #require(await operations.drafts.last)
    #expect(draft.branch == "fix-login" && !draft.createBranch && draft.base.isEmpty)
    #expect(draft.title == "Finish the login fix" && created().last?.1 == "Finish the login fix")
    #expect(model.branchMode == .newBranch && model.workBranch.isEmpty, "The next session is a new branch again")
    model.branchMode = .existing; model.choose("fix-login")
    model.text = ""
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.title) } ?? ("", "x") == ("fix-login", ""))
    #expect(created().last.map { $0.1 == nil } == true, "Nothing typed, no prompt")
    model.branchMode = .existing; model.choose("fix-login")
    // A shell takes no prompt; the text still names the session.
    model.select(.shell); model.text = "poke at it"
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.title) } ?? ("", "") == ("fix-login", "poke at it"))
    #expect(created().last.map { $0.1 == nil } == true)
    model.branchMode = .existing; model.text = ""; model.choose("fix-login")
    await operations.setPullRequestBranch("fix-login")
    model.select(.claude)
    #expect(model.placeholderText == "Describe what to do on this branch (optional)")
    // A link names its own branch: Existing branch does not apply to it.
    model.text = "https://github.com/o/r/pull/7"
    #expect(!model.usesExistingBranch && model.chosenBranch == model.base, "With a link, the chooser picks the base")
    await model.submit()
    #expect(await operations.drafts.last.map { ($0.branch, $0.url) } ?? ("", "") == ("fix-login", "https://github.com/o/r/pull/7"))
    #expect(model.branchMode == .existing && model.workBranch == "fix-login",
            "A link on the picked branch is not working on it: the pick stays for the next session")
}

@MainActor @Test func existingBranchRefusesABranchASessionAlreadyWorksOn() async throws {
    let operations = StartOperations()
    let (model, _) = await composer(operations)
    model.branchMode = .existing; model.choose("fix-login")
    model.updateSessions([WorkspaceSession(id: "s9", projectId: homeProject.id, workspace: homeProject.workspace, worktree: "/tmp/w",
                                           title: "Login fix", branch: "fix-login", url: "", createdAt: nil, pinned: false),
                          WorkspaceSession(id: "o1", projectId: "other", workspace: "/tmp/o", worktree: "/tmp/o",
                                           title: "Elsewhere", branch: "main", url: "", createdAt: nil, pinned: false)])
    #expect(!model.canStart && model.hint?.isError == true, "A branch a session already works on can't be started on again")
    await model.submit()
    #expect(await operations.drafts.isEmpty)
    model.choose("main")
    #expect(model.workBranch == "main" && model.canStart, "Another project's session on the same name doesn't count")
    #expect(!model.choose("fix-login") && model.workBranch == "main", "A taken branch can't be picked")
    model.branchMode = .newBranch
    #expect(model.choose("fix-login") && model.base == "fix-login", "Forking from it is fine")
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

/// Start opened on a pull request link from a row carries the ticket the PR references, recorded on
/// the session made from that same link when its lookup names none; edited away, the key goes too.
@MainActor @Test func openingStartOnALinkFillsItInAndRecordsTheTicketItReferences() async throws {
    let operations = StartOperations()
    let (model, _) = await composer(operations)
    let focus = model.focusRequest
    model.prepare(text: "https://github.com/o/r/pull/7", jiraKey: "rec-9", agent: .codex)
    #expect(model.text == "https://github.com/o/r/pull/7" && model.agent == .codex && model.focusRequest == focus + 1)
    await model.submit()
    let first = await operations.drafts.last
    #expect(first?.jiraKey == "REC-9" && first?.url == "https://github.com/o/r/pull/7")
    model.prepare(text: "https://github.com/o/r/pull/8", jiraKey: "REC-10", agent: nil)
    model.text = "https://github.com/o/r/pull/11"
    await model.submit()
    let edited = await operations.drafts.last
    #expect(edited?.jiraKey == "" && edited?.url == "https://github.com/o/r/pull/11")
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
    model.prepare(text: "late", agent: nil)
    #expect(model.text == "Try this")
}

@Test func theFirstPromptRidesOnTheLaunchAsOneQuotedArgument() {
    let plain = SessionAgent.claude.command(sessionID: "id", fresh: true)
    let oneLine = SessionAgent.claude.command(sessionID: "id", fresh: true, prompt: "Fix it's broken")
    #expect(oneLine == (plain ?? "") + " 'Fix it'\"'\"'s broken'")
    // Line breaks survive, in quoting that keeps the typed command on one line.
    let lines = SessionAgent.claude.command(sessionID: "id", fresh: true, prompt: "Fix it's\n\tbroken \\ now\n")
    #expect(lines == (plain ?? "") + #" $'Fix it\'s\n\tbroken \\ now'"#)
    #expect(lines?.contains("\n") == false)
    #expect(SessionAgent.promptLine("a\nb") == "a b")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "--help me") == "codex ' --help me'")
    #expect(SessionAgent.codex.command(sessionID: nil, prompt: "  \n ") == "codex")
    #expect(SessionAgent.shell.command(sessionID: nil, prompt: "anything") == nil)
}


@MainActor private func pageModel() -> ProjectPageViewModel {
    let editor = ProjectEditorViewModel(project: homeProject, service: ProjectPageService(), chooseFolder: { nil })
    return ProjectPageViewModel(project: homeProject, editor: editor,
                                composer: ProjectComposerModel(project: homeProject, agent: .claude, operations: nil))
}

