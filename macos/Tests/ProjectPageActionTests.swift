import Foundation
import Testing

actor ProjectPageGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(failing: Bool = false) {
        let pending = continuation; continuation = nil
        if failing { pending?.resume(throwing: BackendError.operation("Late open failure")) }
        else { pending?.resume() }
    }
}

@MainActor final class ProjectPageActions: PageActionServing, DesktopActions {
    var opened: [OpenPageRequest] = [], navigated: [String] = [], copied: [String] = [], browsers: [URL] = []
    var browserSucceeds = true, failOpen = false
    var gate: ProjectPageGate?
    func openPage(_ request: OpenPageRequest) async throws {
        opened.append(request)
        if let gate { self.gate = nil; try await gate.wait() }
        try Task.checkCancellation()
        if failOpen { throw BackendError.operation("Fixture open failed") }
        navigated.append(request.url)
    }
    func openBrowser(_ url: URL) -> Bool { browsers.append(url); return browserSucceeds }
    func copy(_ value: String) { copied.append(value) }
    func reveal(_ url: URL) {}
}

struct ProjectPageService: ProjectService {
    func load(_ id: String) throws -> Project { throw CancellationError() }
    func save(_ draft: ProjectDraft, id: String?) throws -> Project { throw CancellationError() }
    func delete(_ id: String) {}
    func detectRepository(_ path: String) -> String { "" }
    func pullRequests(_ id: String, state: String, force: Bool) -> ProjectPRSnapshot { .init() }
}

@MainActor final class ProjectPageRuntime: ProjectCoordinating {
    var owns = true
    func ownsProject(_ id: String) -> Bool { owns }
    func applyProjectSave(_ project: Project, source: ProjectSaveSource) {}
    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel) {}
}

@MainActor private func actionProject(_ actions: any PageActionServing) throws -> ProjectPageViewModel {
    let project = Project(id: "actions", name: "Actions", repo: "fixture/repo", color: nil, workspace: "/tmp/fixture", jiraProjectKey: "APP")
    let service = ProjectPageService()
    let model = ProjectPageViewModel(project: project, service: service,
        editor: ProjectEditorViewModel(project: project, service: service, chooseFolder: { nil }), pageActions: actions)
    let prs = try JSONDecoder().decode([DashboardPR].self, from: Data(#"""
    [{"number":1,"title":"Mine","url":"https://github.com/fixture/repo/pull/1","state":"OPEN","category":"mine"},
     {"number":2,"title":"Reviewed","url":"https://github.com/fixture/repo/pull/2","repo":"fixture/repo","headRefName":"feature/review","author":{"login":"reviewer"},"state":"OPEN","category":"other","awaitingMyReview":true},
     {"number":3,"title":"Other","url":"https://github.com/fixture/repo/pull/3","state":"OPEN","category":"other"},
     {"number":4,"title":"Not in review orbit","url":"https://github.com/fixture/repo/pull/4","state":"OPEN","category":"review","awaitingMyReview":false}]
    """#.utf8))
    model.update(project, snapshot: prs)
    return model
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPageActionsAreCoordinatorOwnedAndKeepErrorsLocal() async throws {
    let actions = ProjectPageActions(), model = try actionProject(actions)
    let runtime = ProjectPageRuntime(), root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installProject(model, runtime: runtime)
    let review = model.rows[1], other = model.rows[2]
    #expect(model.rows[3].openPageRequest.category == "other")
    model.open(review); model.openSession(review)
    #expect(actions.opened.isEmpty && model.opening.isEmpty)
    root.navigate(to: .project(model.project.id))
    actions.failOpen = true
    model.open(review)
    while !model.opening.isEmpty { await Task.yield() }
    #expect(model.actionError?.contains("Fixture open failed") == true && model.error == nil)
    actions.failOpen = false; model.open(review)
    while !model.opening.isEmpty { await Task.yield() }
    let opened = try #require(actions.opened.last)
    #expect(opened.category == "review" && opened.repo == "fixture/repo" && opened.branch == "feature/review" && opened.login == "reviewer")
    #expect(model.actionError == nil && actions.navigated == [review.url.absoluteString])
    model.open(other)
    while !model.opening.isEmpty { await Task.yield() }
    #expect(actions.opened.last?.category == "other")
    model.editor.requestDeletion()
    model.open(other); model.openSession(other)
    #expect(actions.opened.count == 3 && model.opening.isEmpty)
    child.cancelDeletion(id: try #require(child.deletionConfirmation).id)
    model.setSearch("Mine")
    model.openSession(review); model.open(review)
    #expect(actions.opened.count == 3 && model.opening.isEmpty)
    runtime.owns = false; model.openSession(model.rows[0])
    #expect(actions.opened.count == 3 && model.opening.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPageActionsCoalesceAndLatestOpenSupersedesEarlierRequest() async throws {
    let gate = ProjectPageGate(), actions = ProjectPageActions()
    actions.gate = gate
    let model = try actionProject(actions)
    let coordinator = ProjectCoordinator(model: model)
    let first = model.rows[0], second = model.rows[1]
    model.open(first); model.open(first)
    await gate.waitForStart()
    #expect(actions.opened.count == 1 && model.opening == [first.id])
    model.open(second)
    while !model.opening.isEmpty { await Task.yield() }
    await gate.finish(failing: true)
    await Task.yield()
    #expect(actions.navigated == [second.url.absoluteString] && model.actionError == nil && model.opening.isEmpty)
    coordinator.retire()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["leave", "dialog", "section", "disconnect", "retire"])
func projectPageActionsCancelPendingNavigationWhenTheirContextChanges(change: String) async throws {
    let gate = ProjectPageGate(), actions = ProjectPageActions()
    actions.gate = gate
    let model = try actionProject(actions), runtime = ProjectPageRuntime()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installProject(model, runtime: runtime)
    root.navigate(to: .project(model.project.id)); model.open(model.rows[0])
    await gate.waitForStart()
    switch change {
    case "leave": root.navigate(to: .overview)
    case "dialog": root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    case "section": model.selectSection(.tickets)
    case "disconnect": model.connect(nil)
    default: child.retire()
    }
    #expect(model.opening.isEmpty)
    await gate.finish(); await Task.yield()
    #expect(actions.navigated.isEmpty && model.actionError == nil)
    if let sheet = root.sheet { root.dismissSheet(id: sheet.id) }
    child.retire()
    model.open(model.rows[0]); model.openSession(model.rows[0])
    model.connect(ProjectPageService()); await model.refresh()
    #expect(model.retired && actions.opened.count == 1 && model.opening.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPageOpenEmitsTheResolvedRequestAndSkipsRowsNoLongerShown() async throws {
    let actions = ProjectPageActions(), model = try actionProject(actions)
    var emitted: [ProjectPageViewModel.Action] = []
    model.onAction = { emitted.append($0) }
    let row = model.rows[0]
    model.open(row, inTab: true)
    model.openSession(row, agent: .claude)
    var tab = row.openPageRequest; tab.inTab = true
    #expect(emitted == [.pullRequest(tab), .pullRequest(DashboardViewModel.sessionRequest(row, agent: .claude))])
    // A row the snapshot no longer shows resolves to nothing, so nothing reaches the coordinator.
    emitted = []
    model.setSearch("No such title in these fixtures")
    model.open(row); model.openSession(row)
    #expect(emitted.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1))) func projectPageActionFactoryInjectsOpeningWithoutDashboard() async throws {
    let actions = ProjectPageActions()
    let native = NativeProjectFeatureFactory(creation: NativeCreationFlowFactory(chooseFolder: { nil }))
    let project = try actionProject(actions)
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!)
    let services = ProjectFeatureServices(projects: ProjectPageService(), tickets: APIJiraService(api: api),
        workflows: APIWorkflowService(api: api), automation: APIAutomationService(api: api), api: api, baseURL: URL(string: "http://127.0.0.1:12345")!)
    let model = native.project(project.project, services: services, openPage: actions.openPage)
    model.update(project.project, snapshot: project.prs)
    let coordinator = ProjectCoordinator(model: model)
    model.open(model.rows[1])
    while !model.opening.isEmpty { await Task.yield() }
    #expect(actions.opened.count == 1)
    coordinator.retire()
}
