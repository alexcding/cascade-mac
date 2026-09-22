import AppKit
import Foundation
import Testing

private actor RecordingTerminalControl: TerminalRuntimeControlling {
    var paired: [Set<String>] = []
    var quits = 0
    func stopPaired(keys: Set<String>) { paired.append(keys) }
    func stopExisting() { quits += 1 }
}

@MainActor private final class RecordingAppPlatform: AppPlatformFactory {
    let homeDirectory = "/tmp/craft-injected-home"
    let control = RecordingTerminalControl()
    var requests: [AppTerminalRequest] = []
    var viewerCreations = 0
    var launcherCreations = 0
    var actionCreations = 0
    private var native: NativeAppPlatformFactory {
        NativeAppPlatformFactory(homeDirectory: homeDirectory,
            configuration: { throw BackendError.configuration("Injected terminal configuration unavailable") })
    }
    func viewer(dialogs: BrowserDialogCoordinator,
                documents: any DocumentFeatureFactory, close: EditorCloseCoordinator) -> ViewerStore {
        viewerCreations += 1
        return native.viewer(dialogs: dialogs, documents: documents, close: close)
    }
    func workspaceLauncher() -> WorkspaceLaunchViewModel { launcherCreations += 1; return native.workspaceLauncher() }
    func terminal(_ request: AppTerminalRequest) -> TerminalSession { requests.append(request); return native.terminal(request) }
    func detachedShell(_ request: AppTerminalRequest) -> DetachedShell { native.detachedShell(request) }
    func terminalControl() -> any TerminalRuntimeControlling { control }
    func workflowTerminal(_ terminal: TerminalSession, cli: WorkflowCLI, sessionID: String?) async throws -> any WorkflowTerminal {
        try await native.workflowTerminal(terminal, cli: cli, sessionID: sessionID)
    }
    func resources(api: APIClient?) -> any ResourceUsageService { native.resources(api: api) }
    func pageActions(open: @escaping (OpenPageRequest) async throws -> Void,
                     session: @escaping (OpenPageRequest) -> PageSessionMark?) -> any PageActionServing {
        actionCreations += 1; return native.pageActions(open: open, session: session)
    }
}

@MainActor @Test func appPlatformFactoryOwnsScratchSessionAndRestartConstruction() async throws {
    _ = NSApplication.shared
    let suite = "platform-factory-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let platform = RecordingAppPlatform()
    let model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }),
                            shellFactory: NativeShellFeatureFactory(preferences: preferences), platformFactory: platform,
                            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    #expect(platform.viewerCreations == 1 && platform.launcherCreations == 1 && platform.actionCreations == 2)
    model.select(.terminal)
    model.openTerminal(); model.openTerminal()
    #expect(platform.requests == [.init(key: "native-terminal-spike", directory: platform.homeDirectory, paired: false)])
    let scratch = try #require(model.terminal)
    let record = WorkspaceSession(id: "injected-session", projectId: "project", workspace: "/tmp",
        worktree: "/tmp/craft-injected-worktree", title: "Injected session", branch: "", url: "", createdAt: nil, pinned: false)
    model.createdSession(record)
    let original = try #require(model.terminal)
    #expect(platform.requests.last == .init(key: record.id, directory: record.worktree, paired: true))
    model.select(.terminal)
    #expect(model.terminal === scratch)
    model.select(.session(record.id))
    model.restartSession(record)
    let deadline = ContinuousClock.now + .seconds(3)
    while model.terminal === original && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.terminal !== original && platform.requests.count == 3)
    #expect(await platform.control.paired == [[record.id]])
    #expect(platform.requests.last == .init(key: record.id, directory: record.worktree, paired: true))
    await model.stop()
    #expect(await platform.control.quits == 0) // Backend stop never owns detached shells.
}

@MainActor @Test(arguments: [false, true]) func appPlatformControlStopsShellsWheneverTheAppTerminates(update: Bool) async throws {
    _ = NSApplication.shared
    let suite = "platform-quit-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let platform = RecordingAppPlatform()
    let model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }),
                            shellFactory: NativeShellFeatureFactory(preferences: preferences), platformFactory: platform,
                            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    if update { try await model.prepareForUpdate() } else { try await model.quit() }
    #expect(await platform.control.quits == 1)
    #expect(platform.requests.isEmpty)
}

@MainActor @Test func platformTerminalConfigurationFailureCannotFallBackToDailyDaemon() async throws {
    _ = NSApplication.shared
    let factory = NativeAppPlatformFactory(configuration: { throw BackendError.configuration("Injected isolated terminal failure") })
    let session = factory.terminal(.init(key: "isolated", directory: "/tmp", paired: true))
    let view = WorkspaceTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    view.delegate = session.surface; view.controller = session.surface.controller; view.configuration = session.surface.configuration
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.contentView = nil; window.close() }
    view.layoutSubtreeIfNeeded()
    await session.start()
    #expect(session.error == "Injected isolated terminal failure")
    #expect(session.shellPID == nil && session.termID == nil && !session.ready)
    session.disconnect()
    do { try await factory.terminalControl().stopExisting(); Issue.record("Failed configuration unexpectedly stopped a daemon") }
    catch { #expect(error.localizedDescription == "Injected isolated terminal failure") }
}
