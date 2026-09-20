import Foundation
import Testing

private actor OperationGate<Value: Sendable> {
    private var pending: CheckedContinuation<Value, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func value() async throws -> Value {
        try await withCheckedThrowingContinuation {
            pending = $0; started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ result: Result<Value, any Error>) {
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
}

private let operationProject = Project(id: "operation", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
private let operationSession = WorkspaceSession(id: "operation-session", projectId: "operation", workspace: "/tmp/fixture",
    worktree: "/tmp/fixture/session", title: "Operation", branch: "feature", url: "", createdAt: nil, pinned: false)
private let operationDestinations = (BuildSchemes(target: "/tmp/Fixture.xcodeproj", schemes: ["Fixture"]),
    [BuildSimulator(udid: "fixture-simulator", name: "Fixture", runtime: "Fixture OS")])
private let operationSettings = BuildSettings(appPath: "/tmp/Fixture.app", bundleId: "fixture.app", target: "/tmp/Fixture.xcodeproj", configuration: "Debug")

private actor OperationBuildService: BuildServing {
    var loads = 0, settingsReads = 0, saves = 0
    var destinationsGate: OperationGate<(BuildSchemes, [BuildSimulator])>?
    let settingsGate: OperationGate<BuildSettings>?
    init(destinations: OperationGate<(BuildSchemes, [BuildSimulator])>? = nil, settings: OperationGate<BuildSettings>? = nil) {
        destinationsGate = destinations; settingsGate = settings
    }
    var wantedSchemes: [String] = []
    func destinations(project: Project, session: WorkspaceSession, scheme: String) async throws -> (BuildSchemes, [BuildSimulator]) {
        loads += 1; wantedSchemes.append(scheme)
        if let gate = destinationsGate { destinationsGate = nil; return try await gate.value() }
        return operationDestinations
    }
    func settings(project: Project, session: WorkspaceSession, scheme: String, simulator: String) async throws -> BuildSettings {
        settingsReads += 1
        if let settingsGate { return try await settingsGate.value() }
        return operationSettings
    }
    var savedSessions: [String] = [], seededProject: [Bool] = []
    func saveDestination(session: WorkspaceSession, seedingProject: Bool, scheme: String, simulator: String) {
        saves += 1; savedSessions.append(session.id); seededProject.append(seedingProject)
    }
}

@MainActor private final class OperationBuildTerminal: BuildTerminal {
    var commands: [String] = []
    var interrupts = 0
    let shellGate: OperationGate<Bool>?
    init(shell: OperationGate<Bool>? = nil) { shellGate = shell }
    func waitUntilReady() async throws {}
    func atShell() async throws -> Bool {
        if let shellGate { return try await shellGate.value() }
        return false
    }
    func submit(_ line: String) { commands.append(line) }
    func interrupt() { interrupts += 1 }
    func close() {}
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeBuildReplacementRejectsOldLoadAndActions() async throws {
    let gate = OperationGate<(BuildSchemes, [BuildSimulator])>(), service = OperationBuildService(destinations: gate)
    var factories = 0
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.presentBuild { runtime }
    let first = try #require(coordinator.sheet)
    guard case .build(let old) = first.destination else { Issue.record("Wrong destination"); return }
    let oldAction = old.onAction
    let loading = Task { await old.load() }
    await gate.waitForStart()
    coordinator.dismissSheet(id: first.id)
    coordinator.presentBuild { runtime }
    let second = try #require(coordinator.sheet)
    guard case .build(let current) = second.destination else { Issue.record("Wrong destination"); return }
    await current.load()
    #expect(current.canRun && current.scheme == "Fixture")
    old.scheme = "obsolete"; await old.load(); await old.run(); oldAction(.started); old.retire()
    await gate.finish(.success((BuildSchemes(target: "old", schemes: ["Obsolete"]), [])))
    await loading.value
    #expect(old.retired && !old.canRun && !old.loading && current.canRun && current.scheme == "Fixture")
    #expect(coordinator.sheet?.id == second.id && factories == 0)
    #expect(await service.loads == 2)
    #expect(await service.settingsReads == 0)
    coordinator.dismissSheet(id: second.id); runtime.disconnect()
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeBuildDisconnectDuringSettingsCannotPersistOrStart() async {
    let gate = OperationGate<BuildSettings>(), service = OperationBuildService(settings: gate)
    var factories = 0, callbacks = 0
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    let destination = BuildDestinationViewModel(runtime: runtime)
    destination.onAction = { _ in callbacks += 1 }
    await destination.load()
    let run = Task { await destination.run() }
    await gate.waitForStart()
    runtime.disconnect()
    await gate.finish(.success(operationSettings)); await run.value
    await destination.load(); await destination.run(); await runtime.stop()
    #expect(!destination.canRun && !runtime.running && factories == 0 && callbacks == 0)
    #expect(await service.saves == 0)
    #expect(await service.settingsReads == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeBuildDisconnectDuringShellCheckCannotSubmitOrInterrupt() async {
    let gate = OperationGate<Bool>(), service = OperationBuildService()
    let terminal = OperationBuildTerminal(shell: gate)
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { terminal })
    let destination = BuildDestinationViewModel(runtime: runtime)
    await destination.load()
    let run = Task { await destination.run() }
    await gate.waitForStart()
    runtime.disconnect()
    await gate.finish(.success(true)); await run.value
    await runtime.stop()
    #expect(terminal.commands.isEmpty && terminal.interrupts == 0 && !runtime.running)
    #expect(await service.saves == 1)
}

/// Waits for the coordinator's own preparation task to put the dialog up.
@MainActor private func confirming(_ coordinator: AppCoordinator, limit: Int = 500) async {
    for _ in 0..<limit where coordinator.removal?.phase == .preparing { await Task.yield() }
    #expect(coordinator.removal?.phase == .confirming)
}

/// Waits for the coordinator's own removal task to finish with the dialog dismissed.
@MainActor private func settled(_ coordinator: AppCoordinator, limit: Int = 500) async {
    for _ in 0..<limit where coordinator.removal != nil { await Task.yield() }
    #expect(coordinator.removal == nil)
}

private actor OperationRemovalService: SessionRemoving {
    var loads = 0, removals = 0
    let preparation: OperationGate<SessionRemovalPlan>?
    var removal: OperationGate<Void>?
    init(preparation: OperationGate<SessionRemovalPlan>? = nil, removal: OperationGate<Void>? = nil) {
        self.preparation = preparation; self.removal = removal
    }
    func prepare(record: WorkspaceSession, projects: [Project], sessions: [WorkspaceSession]) async throws -> SessionRemovalPlan {
        loads += 1
        if let preparation { return try await preparation.value() }
        return .init(record: record, sessions: [record], removesWorktree: false, holders: [])
    }
    func remove(_ plan: SessionRemovalPlan) async throws {
        removals += 1
        if let gate = removal { removal = nil; try await gate.value() }
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func operationLifetimeDismissedRemovalRejectsPendingPreparation(failing: Bool) async throws {
    let gate = OperationGate<SessionRemovalPlan>(), service = OperationRemovalService(preparation: gate)
    var cleaned = 0, finished = 0
    let model = SessionRemovalViewModel(service: service, record: operationSession, projects: [operationProject], sessions: [operationSession],
        didRemove: { _ in cleaned += 1 }, finished: { finished += 1 })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.presentRemoval { model }
    let request = try #require(coordinator.removal)
    #expect(request.phase == .preparing && !coordinator.canPresent)
    await gate.waitForStart()
    await model.load() // Coalesce duplicate initial loads: the coordinator already started one.
    coordinator.cancelRemoval(id: request.id)
    await gate.finish(failing ? .failure(BackendError.operation("Obsolete preview"))
        : .success(.init(record: operationSession, sessions: [operationSession], removesWorktree: false, holders: [])))
    await model.load(); await model.remove()
    coordinator.presentRemoval { model }
    #expect(model.retired && model.plan == nil && model.error == nil && !model.canRemove && !model.loading)
    #expect(coordinator.removal == nil && coordinator.removalFailure == nil && cleaned == 0 && finished == 0)
    #expect(await service.loads == 1)
    #expect(await service.removals == 0)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func operationLifetimeRemovalRetriesOnceAndCoordinatorPreservesUnrelatedNavigation(selected: Bool) async throws {
    let gate = OperationGate<Void>(), service = OperationRemovalService(removal: gate)
    var cleaned = 0, finished = 0
    let model = SessionRemovalViewModel(service: service, record: operationSession, projects: [operationProject], sessions: [operationSession],
        didRemove: { _ in cleaned += 1 }, finished: { finished += 1 })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.navigate(to: selected ? .session(operationSession.id) : .terminal)
    coordinator.presentRemoval { model }
    let request = try #require(coordinator.removal), oldAction = model.onAction
    await confirming(coordinator)
    coordinator.confirmRemoval(id: request.id)
    await gate.waitForStart()
    // The dialog is gone once removal starts, and cancelling can no longer take it back.
    coordinator.cancelRemoval(id: request.id)
    coordinator.confirmRemoval(id: request.id)
    #expect(coordinator.removal?.phase == .removing && !coordinator.canPresent)
    await gate.finish(.failure(BackendError.operation("Retry removal")))
    await settled(coordinator)
    // A failed removal reports why and retires the attempt; the row is still there to try again.
    #expect(coordinator.removalFailure?.message == "Retry removal" && model.retired)
    #expect(finished == 1 && cleaned == 0 && coordinator.selection == (selected ? .session(operationSession.id) : .terminal))
    coordinator.dismissRemovalFailure(id: try #require(coordinator.removalFailure).id)
    #expect(coordinator.canPresent)
    #expect(await service.removals == 1)
    // A second session removes for real, and only the selected row navigates away.
    let second = SessionRemovalViewModel(service: service, record: operationSession, projects: [operationProject],
                                         sessions: [operationSession], didRemove: { _ in cleaned += 1 }, finished: { finished += 1 })
    coordinator.presentRemoval { second }
    let confirmed = try #require(coordinator.removal)
    await confirming(coordinator)
    coordinator.confirmRemoval(id: confirmed.id)
    await settled(coordinator)
    #expect(second.completed && second.retired && cleaned == 1 && finished == 2)
    #expect(coordinator.removal == nil && coordinator.removalFailure == nil)
    #expect(coordinator.selection == (selected ? .overview : .terminal))
    #expect(await service.removals == 2)
    coordinator.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    let next = try #require(coordinator.sheet)
    oldAction(.removed([operationSession]))
    #expect(coordinator.sheet?.id == next.id)
    coordinator.dismissSheet(id: next.id)
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeRetiredRemovalStillFinishesStartedCleanup() async {
    let gate = OperationGate<Void>(), service = OperationRemovalService(removal: gate)
    var cleaned = 0, finished = 0, callbacks = 0
    let model = SessionRemovalViewModel(service: service, record: operationSession, projects: [operationProject], sessions: [operationSession],
        didRemove: { _ in cleaned += 1 }, finished: { finished += 1 })
    model.onAction = { _ in callbacks += 1 }
    await model.load()
    let remove = Task { await model.remove() }
    await gate.waitForStart()
    model.retire()
    await gate.finish(.success(())); await remove.value
    await model.remove()
    #expect(cleaned == 1 && finished == 1 && callbacks == 0 && model.completed && !model.removing)
    #expect(await service.removals == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func configureDestinationSavesWithoutBuilding() async {
    let service = OperationBuildService()
    var factories = 0, actions: [BuildDestinationViewModel.Action] = []
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    let destination = BuildDestinationViewModel(runtime: runtime, purpose: .configure)
    destination.onAction = { actions.append($0) }
    await destination.load()
    await destination.confirm()
    #expect(destination.retired && !runtime.running && factories == 0)
    #expect(actions.count == 1)
    if case .saved = actions.first {} else { Issue.record("configure must report .saved, got \(actions)") }
    #expect(await service.saves == 1)
    #expect(await service.settingsReads == 0)
}

@MainActor @Test func idleBuildModelAdoptsProjectDestinationButABusyOneKeepsItsOwn() async {
    let service = OperationBuildService()
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { OperationBuildTerminal() })
    var project = operationProject
    project.runScheme = "Other"; project.runSim = "sim-other"
    runtime.adopt(project)
    #expect(runtime.scheme == "Other" && runtime.simulator == "sim-other")
    let destination = BuildDestinationViewModel(runtime: runtime, purpose: .configure)
    destination.scheme = "Sheet"
    project.runScheme = "Later"
    runtime.adopt(project)
    #expect(runtime.scheme == "Sheet", "a presented sheet keeps the user's in-progress choice")
    destination.retire()
    runtime.adopt(project)
    #expect(runtime.scheme == "Later")
}

private func operationSession(_ id: String, scheme: String? = nil, simulator: String? = nil) -> WorkspaceSession {
    WorkspaceSession(id: id, projectId: "operation", workspace: "/tmp/fixture", worktree: "/tmp/fixture/\(id)",
        title: id, branch: id, url: "", createdAt: nil, pinned: false, runScheme: scheme, runSim: simulator)
}

@MainActor @Test(.timeLimit(.minutes(1))) func runWithASavedDestinationStartsWithoutTheSheet() async throws {
    let shell = OperationGate<Bool>()
    let service = OperationBuildService(), terminal = OperationBuildTerminal(shell: shell)
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject,
        session: operationSession("saved", scheme: "Fixture", simulator: "fixture-simulator"),
        terminalFactory: { terminal })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.runBuild { runtime }
    #expect(coordinator.sheet == nil)
    await shell.waitForStart()
    await shell.finish(.success(true))
    while !runtime.running && coordinator.sheet == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(coordinator.sheet == nil && runtime.running && terminal.commands.count == 1)
    #expect(await service.saves == 0, "a direct run changes nothing, so it saves nothing")
    runtime.disconnect()
}

@MainActor @Test(.timeLimit(.minutes(1))) func runWithoutADestinationOrAfterAFailureShowsTheSheet() async throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let fresh = BuildWorkspaceViewModel(service: OperationBuildService(), project: operationProject,
        session: operationSession("fresh"), terminalFactory: { OperationBuildTerminal() })
    coordinator.runBuild { fresh }
    let first = try #require(coordinator.sheet)
    coordinator.dismissSheet(id: first.id); fresh.disconnect()

    struct Rejected: LocalizedError { var errorDescription: String? { "no matching destination" } }
    let gate = OperationGate<BuildSettings>(), service = OperationBuildService(settings: gate)
    let failing = BuildWorkspaceViewModel(service: service, project: operationProject,
        session: operationSession("failing", scheme: "Fixture", simulator: "fixture-simulator"),
        terminalFactory: { OperationBuildTerminal() })
    coordinator.runBuild { failing }
    #expect(coordinator.sheet == nil)
    await gate.waitForStart()
    await gate.finish(.failure(Rejected()))
    while coordinator.sheet == nil { try await Task.sleep(for: .milliseconds(20)) }
    guard case .build(let model) = coordinator.sheet?.destination else { Issue.record("Wrong destination"); return }
    await model.load()
    #expect(model.error == "no matching destination", "the sheet explains why the direct run fell back")
    #expect(!failing.running && model.canRun)
    failing.disconnect()
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionsOfOneProjectKeepTheirOwnDestinations() async {
    let service = OperationBuildService()
    var project = operationProject
    project.runScheme = "Default"; project.runSim = "sim-default"
    let chosen = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("chosen", scheme: "Mine", simulator: "sim-mine"), terminalFactory: { OperationBuildTerminal() })
    let following = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("following"), terminalFactory: { OperationBuildTerminal() })
    #expect(chosen.scheme == "Mine" && chosen.simulator == "sim-mine")
    #expect(following.scheme == "Default" && following.simulator == "sim-default" && following.hasSavedDestination)
    project.runScheme = "Moved"
    chosen.adopt(project); following.adopt(project)
    #expect(chosen.scheme == "Mine" && following.scheme == "Moved")

    let destination = BuildDestinationViewModel(runtime: following, purpose: .configure)
    await destination.load()
    await destination.confirm()
    #expect(await service.savedSessions == ["following"])
    #expect(await service.seededProject == [false], "the project already has a default")
    project.runScheme = "Again"
    following.adopt(project)
    #expect(following.scheme == "Fixture", "a session that chose stops following the project")
}

@Test func runCommandFollowsTheDestinationPlatform() throws {
    var settings = BuildSettings(appPath: "/tmp/Fixture.app", bundleId: "fixture.app", target: "/tmp/Fixture.xcodeproj", configuration: "Debug")
    let simulator = try settings.command(scheme: "Fixture", simulator: "sim-1")
    #expect(simulator.contains("simctl install") && simulator.contains("simctl launch"))
    settings.platform = "macosx"
    #expect(throws: (any Error).self) { try settings.command(scheme: "Fixture", simulator: "mac-1") }
    settings.executablePath = "/tmp/Fixture.app/Contents/MacOS/Fixture"
    let mac = try settings.command(scheme: "Fixture", simulator: "mac-1")
    #expect(mac.contains("-destination 'id=mac-1'") || mac.contains("-destination id=mac-1"))
    #expect(!mac.contains("simctl") && mac.contains("pkill") && mac.contains("/tmp/Fixture.app/Contents/MacOS/Fixture"))
    settings.platform = "iphoneos"
    let device = try settings.command(scheme: "Fixture", simulator: "device-1")
    #expect(!device.contains("simctl") && device.contains("devicectl device install app") && device.contains("process launch --console"))
}

@MainActor @Test(.timeLimit(.minutes(1))) func changingTheSchemeReloadsItsDestinations() async throws {
    let service = OperationBuildService()
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession("schemes"),
        terminalFactory: { OperationBuildTerminal() })
    let destination = BuildDestinationViewModel(runtime: runtime, purpose: .configure)
    await destination.load()
    #expect(destination.scheme == "Fixture" && destination.simulators.count == 1)
    destination.scheme = "Other"
    while await service.loads < 2 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await service.wantedSchemes == ["", "Other"])
    while destination.loading { try await Task.sleep(for: .milliseconds(20)) }
    #expect(destination.scheme == "Fixture" && destination.canRun, "an unknown scheme resolves back to a real one")
    destination.retire(); runtime.disconnect()
}
