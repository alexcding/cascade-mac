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
/// Two destinations, for a pick in the menu that moves.
private let twoDestinations = (operationDestinations.0,
    operationDestinations.1 + [BuildSimulator(udid: "second-simulator", name: "Second", runtime: "Fixture OS")])
private let operationSettings = BuildSettings(appPath: "/tmp/Fixture.app", bundleId: "fixture.app", target: "/tmp/Fixture.xcodeproj", configuration: "Debug")

private actor OperationBuildService: BuildServing {
    var loads = 0, settingsReads = 0, saves = 0
    var destinationsGate: OperationGate<(BuildSchemes, [BuildSimulator])>?
    /// Holds only a fresh look, so a test can see what the menu shows meanwhile.
    var freshGate: OperationGate<(BuildSchemes, [BuildSimulator])>?
    let settingsGate: OperationGate<BuildSettings>?
    var answer: (BuildSchemes, [BuildSimulator])
    func answer(with values: (BuildSchemes, [BuildSimulator])) { answer = values }
    var failsSaves = false
    func failSaves(_ fails: Bool) { failsSaves = fails }
    init(destinations: OperationGate<(BuildSchemes, [BuildSimulator])>? = nil, fresh: OperationGate<(BuildSchemes, [BuildSimulator])>? = nil,
         settings: OperationGate<BuildSettings>? = nil, answer: (BuildSchemes, [BuildSimulator]) = operationDestinations) {
        destinationsGate = destinations; freshGate = fresh; settingsGate = settings; self.answer = answer
    }
    var wantedSchemes: [String] = []
    var refreshes: [Bool] = []
    func destinations(project: Project, session: WorkspaceSession, scheme: String, refresh: Bool) async throws -> (BuildSchemes, [BuildSimulator]) {
        loads += 1; wantedSchemes.append(scheme); refreshes.append(refresh)
        if refresh, let gate = freshGate { freshGate = nil; return try await gate.value() }
        if let gate = destinationsGate { destinationsGate = nil; return try await gate.value() }
        return answer
    }
    func settings(project: Project, session: WorkspaceSession, scheme: String, simulator: String) async throws -> BuildSettings {
        settingsReads += 1
        if let settingsGate { return try await settingsGate.value() }
        return operationSettings
    }
    var savedSessions: [String] = [], seededProject: [Bool] = [], savedSimulators: [String] = []
    struct SaveFailed: LocalizedError { var errorDescription: String? { "could not save" } }
    func saveDestination(session: WorkspaceSession, seedingProject: Bool, scheme: String, simulator: String) throws {
        saves += 1
        if failsSaves { throw SaveFailed() }
        savedSessions.append(session.id); seededProject.append(seedingProject); savedSimulators.append(simulator)
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
    // A project of its own: the destinations cache is shared, and what it holds decides how many
    // loads a run makes.
    let project = Project(id: "operation-replacement", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project, session: operationSession,
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    let old = BuildDestinationViewModel(runtime: runtime)
    let starting = Task { await old.start() }
    await gate.waitForStart()
    #expect(runtime.preparing)
    old.retire()
    // Retiring a Run frees the button at once, though its load has not answered.
    #expect(!runtime.preparing)
    #expect(await old.start() == false)
    let current = BuildDestinationViewModel(runtime: runtime)
    #expect(!current.retired)
    await gate.finish(.success((BuildSchemes(target: "old", schemes: ["Obsolete"]), [])))
    #expect(await starting.value == false)
    #expect(old.retired && runtime.schemes.isEmpty && runtime.error == nil, "the retired Run's answer is dropped, and it says nothing")
    #expect(factories == 0)
    #expect(await service.loads == 1)
    #expect(await service.settingsReads == 0)
    current.retire(); runtime.disconnect()
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeBuildDisconnectDuringSettingsCannotPersistOrStart() async {
    let gate = OperationGate<BuildSettings>(), service = OperationBuildService(settings: gate)
    var factories = 0
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    let destination = BuildDestinationViewModel(runtime: runtime)
    let run = Task { await destination.start() }
    await gate.waitForStart()
    runtime.disconnect()
    await gate.finish(.success(operationSettings))
    #expect(await run.value == false)
    #expect(await destination.start() == false)
    await runtime.stop()
    #expect(!runtime.canRun && !destination.retired && !runtime.running && factories == 0)
    #expect(await service.saves == 0)
    #expect(await service.settingsReads == 1)
}

@MainActor @Test(.timeLimit(.minutes(1))) func operationLifetimeBuildDisconnectDuringShellCheckCannotSubmitOrInterrupt() async {
    let gate = OperationGate<Bool>(), service = OperationBuildService()
    let terminal = OperationBuildTerminal(shell: gate)
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { terminal })
    let destination = BuildDestinationViewModel(runtime: runtime)
    let run = Task { await destination.start() }
    await gate.waitForStart()
    runtime.disconnect()
    await gate.finish(.success(true)); _ = await run.value
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

@MainActor @Test(.timeLimit(.minutes(1))) func aMenuPickSavesWithoutBuilding() async {
    let service = OperationBuildService(answer: twoDestinations)
    var factories = 0
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession("pick"),
        terminalFactory: { factories += 1; return OperationBuildTerminal() })
    await runtime.loadDestinations()
    #expect(runtime.simulator == "fixture-simulator")
    await runtime.choose(simulator: "second-simulator")
    #expect(runtime.simulator == "second-simulator" && !runtime.running && factories == 0)
    #expect(await service.saves == 1)
    #expect(await service.settingsReads == 0)
    // While a run holds the build nothing moves under it.
    let run = BuildDestinationViewModel(runtime: runtime)
    await runtime.choose(simulator: "fixture-simulator")
    #expect(runtime.simulator == "second-simulator")
    #expect(await service.saves == 1)
    run.retire(); runtime.disconnect()
}

/// Selecting a session takes the backend's cached destinations. The menu, where one is chosen,
/// asks afresh, because a device plugged in since is not in the cached answer.
@MainActor @Test(.timeLimit(.minutes(1))) func onlyTheDestinationMenuAsksForDestinationsAfresh() async throws {
    let service = OperationBuildService()
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject,
        session: operationSession("fresh", scheme: "Fresh", simulator: "fixture-simulator"),
        terminalFactory: { OperationBuildTerminal() })
    runtime.warmDestinations()
    while await service.loads < 1 { try await Task.sleep(for: .milliseconds(10)) }
    await runtime.loadDestinations()
    // The menu may also ask for the kept list, if it loads before selection's answer is cached.
    let refreshes = await service.refreshes
    #expect(refreshes.first == false && refreshes.last == true && refreshes.filter { $0 }.count == 1)
    runtime.disconnect()
}

/// With nothing cached in the app, the menu shows what the backend keeps at once and stays usable
/// while the fresh look runs.
@MainActor @Test(.timeLimit(.minutes(1))) func theDestinationMenuShowsTheKeptListBeforeTheFreshLook() async throws {
    let fresh = OperationGate<(BuildSchemes, [BuildSimulator])>()
    let service = OperationBuildService(fresh: fresh)
    let project = Project(id: "operation-kept", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("kept", scheme: "Fixture", simulator: "fixture-simulator"),
        terminalFactory: { OperationBuildTerminal() })
    let loading = Task { await runtime.loadDestinations() }
    await fresh.waitForStart()
    #expect(!runtime.loading && runtime.simulators.count == 1 && runtime.canRun)
    #expect(await service.refreshes == [false, true])
    await fresh.finish(.success(operationDestinations))
    await loading.value
    #expect(runtime.canRun)
    runtime.disconnect()
}

/// With nothing saved, the destination is a simulator though a device is plugged in and listed
/// first; a device is chosen only when it is the one destination.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aPluggedInDeviceIsNeverTheDefaultDestination(alone: Bool) async throws {
    let device = BuildSimulator(udid: "fixture-device", name: "Fixture", runtime: "Fixture OS", kind: .device)
    let simulator = BuildSimulator(udid: "fixture-simulator", name: "Fixture", runtime: "Fixture OS 1.0", kind: .simulator)
    let service = OperationBuildService(answer: (operationDestinations.0, alone ? [device] : [device, simulator]))
    let project = Project(id: "operation-default-\(alone)", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("default-\(alone)", scheme: "Fixture"), terminalFactory: { OperationBuildTerminal() })
    await runtime.loadDestinations()
    #expect(runtime.simulator == (alone ? "fixture-device" : "fixture-simulator"))
    #expect(runtime.hardware.map(\.udid) == ["fixture-device"])
    runtime.disconnect()
}

@MainActor @Test func idleBuildModelAdoptsProjectDestinationButABusyOneKeepsItsOwn() async {
    let service = OperationBuildService()
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession,
        terminalFactory: { OperationBuildTerminal() })
    var project = operationProject
    project.runScheme = "Other"; project.runSim = "sim-other"
    runtime.adopt(project)
    #expect(runtime.scheme == "Other" && runtime.simulator == "sim-other")
    let destination = BuildDestinationViewModel(runtime: runtime)
    project.runScheme = "Later"
    runtime.adopt(project)
    #expect(runtime.scheme == "Other", "a run in flight keeps the destination it was started with")
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

@MainActor @Test(.timeLimit(.minutes(1))) func runWithoutADestinationRunsTheFirstAndAFailureSaysWhy() async throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let first = OperationBuildService()
    let fresh = BuildWorkspaceViewModel(service: first, project: operationProject,
        session: operationSession("fresh"), terminalFactory: { OperationBuildTerminal() })
    coordinator.runBuild { fresh }
    while !fresh.running { try await Task.sleep(for: .milliseconds(20)) }
    #expect(coordinator.sheet == nil && fresh.scheme == "Fixture" && fresh.simulator == "fixture-simulator")
    #expect(await first.saves == 1, "the first run saves what it ran")
    fresh.disconnect()

    struct Rejected: LocalizedError { var errorDescription: String? { "no matching destination" } }
    let gate = OperationGate<BuildSettings>(), service = OperationBuildService(settings: gate)
    let failing = BuildWorkspaceViewModel(service: service, project: operationProject,
        session: operationSession("failing", scheme: "Fixture", simulator: "fixture-simulator"),
        terminalFactory: { OperationBuildTerminal() })
    coordinator.runBuild { failing }
    await gate.waitForStart()
    await gate.finish(.failure(Rejected()))
    while failing.error == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(coordinator.sheet == nil && !failing.running, "the toolbar says why; no sheet")
    #expect(failing.error == "no matching destination")
    failing.disconnect()
}

@MainActor @Test(.timeLimit(.minutes(1))) func sessionsOfOneProjectKeepTheirOwnDestinations() async {
    let service = OperationBuildService(answer: twoDestinations)
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

    await following.loadDestinations()
    await following.choose(simulator: "second-simulator")
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

/// Run ends the copy of the app already running before it launches the new one. When that copy is
/// the Cascade doing the running, a development build on its own scheme, it is asked to leave and
/// the new build opens outside its terminal: a copy under Xcode's debugger cannot be ended, and
/// was left stopped while the new build yielded to it.
@Test func runAsksTheAppThatIsRunningItToLeave() throws {
    var settings = BuildSettings(appPath: "/tmp/Fixture.app", bundleId: "fixture.app", target: "/tmp/Fixture.xcodeproj", configuration: "Debug")
    settings.platform = "macosx"
    settings.executablePath = "/tmp/Fixture.app/Contents/MacOS/Fixture"
    settings.launchArguments = ["--data-dir", "/tmp/dev data"]
    settings.launchEnvironment = ["LOG": "a b"]
    let own = try settings.command(scheme: "Fixture", simulator: "mac-1", host: "/tmp/Fixture.app/Contents/MacOS/../MacOS/Fixture", pid: 4242)
    #expect(own.contains(#" build && { heard=; n=0; while kill -0 4242 2>/dev/null; do "#), "\(own)")
    // Asked on the app's own port, past any proxy; ended like any other app while it cannot hear.
    #expect(own.contains(#"port=$(/bin/cat "$CASCADE_PORT_FILE" 2>/dev/null) && [ -n "$port" ] && /usr/bin/curl -fs --noproxy '*' --connect-timeout 2 -o /dev/null -X POST "http://127.0.0.1:$port/api/hooks/relaunch?pid=4242" && heard=1; } || kill 4242 2>/dev/null; }"#), "\(own)")
    #expect(own.hasSuffix("done; exec /usr/bin/open -n '/tmp/Fixture.app' --env 'LOG=a b' --args '--data-dir' '/tmp/dev data'; }; })"), "\(own)")
    #expect(!own.contains("pkill") && !own.contains("\n"))
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
    shell.arguments = ["-n", "-c", own] // Parse only; nothing is built, asked or opened.
    shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
    try shell.run(); shell.waitUntilExit()
    #expect(shell.terminationStatus == 0)
    // Any other app is ended and takes the terminal, as before.
    let other = try settings.command(scheme: "Fixture", simulator: "mac-1", host: "/Applications/Fixture.app/Contents/MacOS/Fixture", pid: 4242)
    #expect(other.contains("pkill") && other.contains("exec '/tmp/Fixture.app/Contents/MacOS/Fixture' '--data-dir'") && !other.contains("curl"))
    // Only the Mac launch ends anything on this Mac.
    settings.platform = "iphonesimulator"
    #expect(try settings.command(scheme: "Fixture", simulator: "sim-1", host: "/tmp/Fixture.app/Contents/MacOS/Fixture").contains("simctl launch"))
}

/// An app launched here gets what its scheme's Run passes, or it is not the app Xcode launches:
/// Cascade's own scheme names the data folder a development build runs on.
@Test func runCommandPassesWhatTheSchemePasses() throws {
    var settings = BuildSettings(appPath: "/tmp/Fixture.app", bundleId: "fixture.app", target: "/tmp/Fixture.xcodeproj", configuration: "Debug")
    settings.executablePath = "/tmp/Fixture.app/Contents/MacOS/Fixture"
    settings.launchArguments = ["--data-dir", "/tmp/dev data", "it's"]
    settings.launchEnvironment = ["LOG": "a b", "ALSO": "1", "not a name": "x"]
    let launches = [
        "macosx": "export 'ALSO=1' 'LOG=a b' && exec '/tmp/Fixture.app/Contents/MacOS/Fixture'",
        "iphoneos": "export 'DEVICECTL_CHILD_ALSO=1' 'DEVICECTL_CHILD_LOG=a b' && exec /usr/bin/xcrun devicectl device process launch --console --terminate-existing --device 'id-1' -- 'fixture.app'",
        "iphonesimulator": "export 'SIMCTL_CHILD_ALSO=1' 'SIMCTL_CHILD_LOG=a b' && exec /usr/bin/xcrun simctl launch --console-pty --terminate-running-process 'id-1' 'fixture.app'",
    ]
    for (platform, launch) in launches {
        settings.platform = platform
        let command = try settings.command(scheme: "Fixture", simulator: "id-1")
        #expect(command.contains(launch + " '--data-dir' '/tmp/dev data' 'it'\"'\"'s'; }"), "\(platform): \(command)")
        #expect(!command.contains("not a name"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-n", "-c", command] // Parse only; nothing is built or launched.
        shell.standardOutput = FileHandle.nullDevice; shell.standardError = FileHandle.nullDevice
        try shell.run(); shell.waitUntilExit()
        #expect(shell.terminationStatus == 0, "\(platform)")
    }
    // The line is typed into a shell: a line break or a tab in a value is spelled out, not typed.
    settings.launchArguments = ["a\nb\t'c'\\"]; settings.launchEnvironment = ["LINES": "1\r\n2"]; settings.platform = "macosx"
    let spelled = try settings.command(scheme: "Fixture", simulator: "id-1")
    #expect(spelled.contains(#"export $'LINES=1\r\n2' && exec '/tmp/Fixture.app/Contents/MacOS/Fixture' $'a\nb\t\'c\'\\'; }"#))
    #expect(!spelled.contains(where: { $0.isNewline || $0 == "\t" }))
    // A scheme that passes nothing launches as before, on a device too.
    settings.launchArguments = nil; settings.launchEnvironment = [:]
    #expect(try settings.command(scheme: "Fixture", simulator: "id-1").hasSuffix("exec '/tmp/Fixture.app/Contents/MacOS/Fixture'; }; })"))
    settings.platform = "iphoneos"
    #expect(try settings.command(scheme: "Fixture", simulator: "id-1").hasSuffix("--terminate-existing --device 'id-1' 'fixture.app'; })"))
}

@MainActor @Test(.timeLimit(.minutes(1))) func changingTheSchemeReloadsItsDestinations() async throws {
    let service = OperationBuildService()
    let runtime = BuildWorkspaceViewModel(service: service, project: operationProject, session: operationSession("schemes"),
        terminalFactory: { OperationBuildTerminal() })
    await runtime.loadDestinations()
    #expect(runtime.scheme == "Fixture" && runtime.simulators.count == 1)
    await runtime.choose(scheme: "Other")
    // Each load may ask twice, for the kept list and a fresh look; what matters is what it asked for.
    let asked = await service.wantedSchemes.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
    #expect(asked == ["", "Other"])
    #expect(runtime.scheme == "Fixture" && runtime.canRun, "an unknown scheme resolves back to a real one")
    runtime.disconnect()
}

/// Selecting a session and its toolbar both ask for the kept lists: one request, and the menu
/// shows what it answered.
@MainActor @Test(.timeLimit(.minutes(1))) func warmingTwiceAsksOnceAndFillsTheMenu() async throws {
    let gate = OperationGate<(BuildSchemes, [BuildSimulator])>(), service = OperationBuildService(destinations: gate)
    let project = Project(id: "operation-warm", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project, session: operationSession("warm"),
        terminalFactory: { OperationBuildTerminal() })
    runtime.warmDestinations(); runtime.warmDestinations()
    await gate.waitForStart()
    await gate.finish(.success(operationDestinations))
    while runtime.schemes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    runtime.warmDestinations()
    #expect(await service.loads == 1 && runtime.simulators.count == 1 && runtime.canRun)
    runtime.disconnect()
}

/// A load nobody asked for fails quietly: the menu shows why, the toolbar's line is for a Run.
@MainActor @Test(.timeLimit(.minutes(1))) func aBackgroundLoadFailsQuietly() async throws {
    struct Unlisted: LocalizedError { var errorDescription: String? { "xcodebuild -list failed" } }
    let gate = OperationGate<(BuildSchemes, [BuildSimulator])>(), service = OperationBuildService(destinations: gate)
    let project = Project(id: "operation-quiet", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("quiet", scheme: "Fixture", simulator: "fixture-simulator"), terminalFactory: { OperationBuildTerminal() })
    let loading = Task { await runtime.loadDestinations() }
    await gate.waitForStart()
    await gate.finish(.failure(Unlisted()))
    await loading.value
    #expect(runtime.error == "xcodebuild -list failed" && runtime.quietError)
    runtime.disconnect()
}

/// Selecting a session warms the menu's lists; when that fails the menu says why instead of
/// saying it is loading with nothing loading.
@MainActor @Test(.timeLimit(.minutes(1))) func aFailedWarmSaysWhyInTheMenu() async throws {
    struct Unlisted: LocalizedError { var errorDescription: String? { "xcodebuild -list failed" } }
    let gate = OperationGate<(BuildSchemes, [BuildSimulator])>(), service = OperationBuildService(destinations: gate)
    let project = Project(id: "operation-warm-failed", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project, session: operationSession("warm-failed"),
        terminalFactory: { OperationBuildTerminal() })
    runtime.warmDestinations()
    await gate.waitForStart()
    await gate.finish(.failure(Unlisted()))
    while runtime.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.error == "xcodebuild -list failed" && runtime.quietError && runtime.schemes.isEmpty)
    runtime.disconnect()
}

/// The list the backend keeps can predate a device plugged in since. The saved destination stays
/// chosen; Run looks afresh, and says it is not available rather than building elsewhere.
@MainActor @Test(.timeLimit(.minutes(1))) func aSavedDestinationTheKeptListLacksStaysChosen() async throws {
    let service = OperationBuildService()
    let project = Project(id: "operation-unplugged", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("unplugged", scheme: "Fixture", simulator: "device"), terminalFactory: { OperationBuildTerminal() })
    runtime.warmDestinations()
    while runtime.schemes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.simulator == "device" && runtime.destinationUnavailable)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.runBuild { runtime }
    while runtime.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!runtime.running && !runtime.quietError && runtime.simulator == "device")
    #expect(await service.refreshes.last == true, "Run looked afresh before saying so")
    #expect(await service.settingsReads == 0)
    #expect(await service.saves == 0)
    // Plugged in: the next list has it again, and picking it answers what Run said.
    await service.answer(with: (operationDestinations.0, operationDestinations.1 + [BuildSimulator(udid: "device", name: "Device", runtime: "Fixture OS")]))
    await runtime.loadDestinations()
    #expect(runtime.simulator == "device" && !runtime.destinationUnavailable && runtime.canRun)
    await runtime.choose(simulator: "device")
    #expect(runtime.error == nil)
    #expect(await service.saves == 0, "it was already saved")
    runtime.disconnect()
}

/// A pick is saved as it is made; one whose save failed is still what Run runs, and Run saves it.
@MainActor @Test(.timeLimit(.minutes(1))) func aPickWhoseSaveFailedIsWhatRunRuns() async throws {
    let service = OperationBuildService(answer: twoDestinations)
    let project = Project(id: "operation-unsaved", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("unsaved", scheme: "Fixture", simulator: "fixture-simulator"), terminalFactory: { OperationBuildTerminal() })
    await runtime.loadDestinations()
    await service.failSaves(true)
    await runtime.choose(simulator: "second-simulator")
    #expect(runtime.error == "could not save" && runtime.simulator == "second-simulator")
    await service.failSaves(false)
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.runBuild { runtime }
    while !runtime.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.error == nil && runtime.simulator == "second-simulator")
    #expect(await service.saves == 2)
    #expect(await service.savedSessions == ["unsaved"])
    runtime.disconnect()
}

/// Two quick picks: the saves go in order, and the last pick is the saved one, so Run takes it as is.
@MainActor @Test(.timeLimit(.minutes(1))) func twoQuickPicksLeaveTheLastOneSaved() async throws {
    let service = OperationBuildService(answer: twoDestinations)
    let project = Project(id: "operation-quick", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project,
        session: operationSession("quick", scheme: "Fixture", simulator: "fixture-simulator"), terminalFactory: { OperationBuildTerminal() })
    await runtime.loadDestinations()
    async let first: Void = runtime.choose(simulator: "second-simulator")
    async let second: Void = runtime.choose(simulator: "fixture-simulator")
    _ = await (first, second)
    #expect(await service.savedSimulators == ["second-simulator", "fixture-simulator"])
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.runBuild { runtime }
    while !runtime.running && runtime.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.running && runtime.error == nil)
    #expect(await service.saves == 2, "the last pick was saved, so Run saves nothing")
    runtime.disconnect()
}

/// A Run that cannot start says why, under the scheme.
@MainActor @Test(.timeLimit(.minutes(1))) func runWithNothingToRunSaysWhy() async throws {
    let service = OperationBuildService(answer: (BuildSchemes(target: "/tmp/Fixture.xcodeproj", schemes: []), []))
    let project = Project(id: "operation-empty", name: "Operation", repo: "", color: nil, workspace: "/tmp/fixture", ide: "xcode")
    let runtime = BuildWorkspaceViewModel(service: service, project: project, session: operationSession("empty"),
        terminalFactory: { OperationBuildTerminal() })
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    coordinator.runBuild { runtime }
    while runtime.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.error == "The project has no scheme to run." && !runtime.quietError && !runtime.running)
    #expect(await service.settingsReads == 0)
    runtime.disconnect()
}
