import Foundation
import Testing

/// A project folder on main with two worktrees; listing fails once `failure` is set.
private actor CheckoutOperations: SessionCreating {
    var failure: String?
    func fail(_ message: String?) { failure = message }
    func references(_ project: Project) throws -> GitReferences {
        if let failure { throw BackendError.operation(failure) }
        return GitReferences(branches: ["main", "zeta", "alpha"].map { .init(name: $0) }, defaultBranch: "main",
                             worktrees: [.init(branch: "zeta", isMain: false, path: "/tmp/w/zeta"),
                                         .init(branch: "main", isMain: true, path: "/tmp/widgets"),
                                         .init(branch: "alpha", isMain: false, path: "/tmp/w/alpha")])
    }
    func resolvePage(_ raw: String, project: Project, draft: SessionDraft) -> SessionDraft { draft }
    func create(project: Project, draft: SessionDraft) throws -> WorkspaceSession { throw CancellationError() }
    func switchMainCheckout(to branch: String, project: Project) {}
}

private func widgets(workspace: String = "/tmp/widgets") -> Project {
    Project(id: "p", name: "Widgets", repo: "acme/widgets", color: nil, workspace: workspace)
}

@MainActor private func panel(_ operations: CheckoutOperations?, defaults: UserDefaults, workspace: String = "/tmp/widgets") -> ProjectTerminalViewModel {
    let project = widgets(workspace: workspace)
    return ProjectTerminalViewModel(project: project, operations: operations, defaults: defaults)
}

private func scratchDefaults() -> UserDefaults {
    let name = "ProjectTerminalTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// What the panel asked the app for: each request's checkout and id, and how many closes.
@MainActor private final class Requests {
    var opened: [(directory: String, id: UUID)] = []
    var closes = 0
    func wire(_ model: ProjectTerminalViewModel) {
        model.requestTerminal = { [unowned self] in opened.append(($0, $1)) }
        model.closeTerminal = { [unowned self] in closes += 1 }
    }
}

@MainActor @Test func projectTerminalOpensANewShellAndClosingStopsIt() {
    let model = panel(nil, defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    #expect(!model.shown)
    model.toggle()
    #expect(model.shown && model.pending && requests.opened.map(\.directory) == ["/tmp/widgets"])
    model.attach(TerminalSession(), request: requests.opened[0].id)
    #expect(model.terminal != nil && !model.pending)

    // Closing stops the shell; opening again makes a new one.
    model.toggle()
    #expect(!model.shown && model.terminal == nil && requests.closes == 1)
    model.toggle()
    #expect(requests.opened.count == 2 && model.terminal == nil && model.pending)
}

@MainActor @Test func projectTerminalIgnoresAnAnswerToARequestItNoLongerWaitsFor() {
    let model = panel(nil, defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    model.toggle()
    let first = requests.opened[0].id
    // Closed and opened again before the first answer came.
    model.toggle(); model.toggle()
    model.attach(TerminalSession(), request: first)
    model.requestFailed("late", request: first)
    #expect(model.terminal == nil && model.pending && model.error == nil)
    model.attach(TerminalSession(), request: requests.opened[1].id)
    #expect(model.terminal != nil)

    // Closed with an answer outstanding: the answer is dropped.
    model.toggle(); model.toggle()
    model.toggle()
    model.attach(TerminalSession(), request: requests.opened[2].id)
    #expect(!model.shown && model.terminal == nil)
}

@MainActor @Test func projectTerminalMovesToAWorktreeWithANewShell() async {
    let model = panel(CheckoutOperations(), defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    // Read before opening, which reads them again with the same answer.
    await model.loadLocations()
    model.toggle()
    model.attach(TerminalSession(), request: requests.opened[0].id)
    #expect(model.locations.map(\.title) == ["main", "alpha", "zeta"])
    #expect(model.locationTitle == "main")

    // The bar names the worktree once its shell is there.
    model.open(model.locations[2])
    #expect(requests.opened.last!.directory == "/tmp/w/zeta" && model.locationTitle == "main")
    model.attach(TerminalSession(), request: requests.opened.last!.id)
    #expect(model.locationTitle == "zeta")
    // The checkout it is already in is no move.
    model.open(model.locations[2])
    #expect(requests.opened.count == 2)
}

@MainActor @Test func aFailedMoveLeavesTheBarOnTheOldCheckoutWithItsReason() async {
    let model = panel(CheckoutOperations(), defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    // Read before opening, which reads them again with the same answer.
    await model.loadLocations()
    model.toggle()
    model.attach(TerminalSession(), request: requests.opened[0].id)
    model.open(model.locations[1])
    model.requestFailed("daemon unreachable", request: requests.opened[1].id)
    #expect(model.locationTitle == "main" && model.terminal == nil && !model.pending)
    #expect(model.error == "daemon unreachable")
    // Closing and opening again is the retry, back in the checkout that worked.
    model.toggle(); model.toggle()
    #expect(requests.opened.last!.directory == "/tmp/widgets" && model.error == nil)
}

@MainActor @Test func projectTerminalReportsWorktreesThatCannotBeRead() async {
    let operations = CheckoutOperations()
    await operations.fail("not a git checkout")
    let model = panel(operations, defaults: scratchDefaults())
    await model.loadLocations()
    #expect(model.locations.isEmpty && model.error == "not a git checkout" && !model.loadingLocations)
}

@MainActor @Test func projectTerminalHeightIsClampedAndKept() {
    let defaults = scratchDefaults()
    let model = panel(nil, defaults: defaults)
    #expect(model.height == ProjectTerminalViewModel.defaultHeight)
    model.resize(to: 10)
    #expect(model.height == ProjectTerminalViewModel.minimumHeight)
    model.resize(to: 420)
    #expect(panel(nil, defaults: defaults).height == 420)
}

@MainActor @Test func retiredProjectTerminalRefusesEverything() async {
    let model = panel(CheckoutOperations(), defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    model.toggle()
    model.retire()
    model.attach(TerminalSession(), request: requests.opened[0].id)
    model.toggle()
    await model.loadLocations()
    #expect(requests.opened.count == 1 && requests.closes == 0 && model.terminal == nil && model.locations.isEmpty)
}

@MainActor @Test func aWorkspaceInsideTheCheckoutIsTheFirstLocationAndTheShellCanGoBackToIt() async {
    // A subfolder of the checkout, written with a trailing slash.
    let model = panel(CheckoutOperations(), defaults: scratchDefaults(), workspace: "/tmp/widgets/app/")
    let requests = Requests(); requests.wire(model)
    await model.loadLocations()
    #expect(model.locations.map(\.path) == ["/tmp/widgets/app/", "/tmp/w/alpha", "/tmp/w/zeta"])
    #expect(model.locations[0].isProjectFolder && model.locations[0].title == "main")
    #expect(model.isCurrent(model.locations[0]) && model.locationTitle == "main")

    model.toggle()
    model.attach(TerminalSession(), request: requests.opened[0].id)
    model.open(model.locations[0])
    #expect(requests.opened.count == 1)
    model.open(model.locations[1])
    model.attach(TerminalSession(), request: requests.opened[1].id)
    model.open(model.locations[0])
    #expect(requests.opened.last!.directory == "/tmp/widgets/app/")
}

@MainActor @Test func aNewWorkspaceFolderTakesTheShellOnlyWhenItRanInTheOldOne() async throws {
    let model = panel(CheckoutOperations(), defaults: scratchDefaults())
    let requests = Requests(); requests.wire(model)
    await model.loadLocations()
    model.toggle()
    model.attach(TerminalSession(), request: requests.opened[0].id)

    // Saved with nothing about the folder changed, or the same folder written another way: nothing moves.
    model.update(widgets())
    model.update(widgets(workspace: "/tmp/widgets/"))
    model.update(widgets(workspace: "/tmp/./widgets"))
    #expect(requests.opened.count == 1)

    model.update(widgets(workspace: "/tmp/gadgets"))
    #expect(requests.opened.last!.directory == "/tmp/gadgets")
    model.attach(TerminalSession(), request: requests.opened.last!.id)
    #expect(model.directory == "/tmp/gadgets")

    // A shell in a worktree stays there. The new folder's worktrees are read by the panel itself.
    // No worktree holds /tmp/gadgets, so all three are listed after the folder itself.
    await model.locationsLoad?.value
    #expect(model.locations.map(\.path) == ["/tmp/gadgets", "/tmp/w/alpha", "/tmp/widgets", "/tmp/w/zeta"])
    let alpha = try #require(model.locations.first { $0.title == "alpha" })
    model.open(alpha)
    model.attach(TerminalSession(), request: requests.opened.last!.id)
    let count = requests.opened.count, worktree = model.directory
    #expect(worktree == "/tmp/w/alpha")
    model.update(widgets(workspace: "/tmp/elsewhere"))
    #expect(requests.opened.count == count && model.directory == worktree)

    // A move to a worktree still under way when the folder changes is kept.
    await model.locationsLoad?.value
    model.open(try #require(model.locations.first { $0.isProjectFolder }))
    model.attach(TerminalSession(), request: requests.opened.last!.id)
    #expect(model.directory == "/tmp/elsewhere")
    await model.locationsLoad?.value
    model.open(try #require(model.locations.first { $0.title == "zeta" }))
    let move = requests.opened.last!
    model.update(widgets(workspace: "/tmp/moved"))
    #expect(requests.opened.last!.id == move.id)
    model.attach(TerminalSession(), request: move.id)
    #expect(model.directory == "/tmp/w/zeta")
}

@MainActor @Test func aRetiredPanelKeepsItsError() async {
    let operations = CheckoutOperations()
    await operations.fail("not a git checkout")
    let model = panel(operations, defaults: scratchDefaults())
    await model.loadLocations()
    model.retire()
    model.dismissError()
    #expect(model.error == "not a git checkout")
}
