import AppKit
import Foundation
import Testing

private actor RecordingTerminalControl: TerminalRuntimeControlling {
    var paired: [Set<String>] = []
    var quits = 0
    func stopPaired(keys: Set<String>) { paired.append(keys) }
    func stopExisting() { quits += 1 }
    func pairedShells() -> [String: Int32] { [:] }
}

@MainActor private final class RecordingAppPlatform: AppPlatformFactory {
    let homeDirectory = "/tmp/cascade-injected-home"
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
    func processSampler() -> any ProcessSampling { native.processSampler() }
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
                            shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil), platformFactory: platform,
                            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    #expect(platform.viewerCreations == 1 && platform.launcherCreations == 1 && platform.actionCreations == 2)
    model.select(.terminal)
    model.openTerminal(); model.openTerminal()
    #expect(platform.requests == [.init(key: "native-terminal-spike", directory: platform.homeDirectory, paired: false)])
    let scratch = try #require(model.terminal)
    let record = WorkspaceSession(id: "injected-session", projectId: "project", workspace: "/tmp",
        worktree: "/tmp/cascade-injected-worktree", title: "Injected session", branch: "", url: "", createdAt: nil, pinned: false)
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

/// Reattaching a stopped session swaps in a new terminal and stops no shell; a live one is left alone.
@MainActor @Test func reattachingAStoppedSessionReplacesItsTerminalAndStopsNoShell() async throws {
    _ = NSApplication.shared
    let suite = "platform-reattach-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let platform = RecordingAppPlatform()
    let model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }),
                            shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil), platformFactory: platform,
                            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    let record = WorkspaceSession(id: "injected-session", projectId: "project", workspace: "/tmp",
        worktree: "/tmp/cascade-injected-worktree", title: "Injected session", branch: "", url: "", createdAt: nil, pinned: false)
    model.createdSession(record)
    let original = try #require(model.terminal)
    model.reattachSession(record.id)
    #expect(model.changingSessions.isEmpty && model.terminal === original)
    model.select(.overview)
    original.disconnect()
    model.reattachSession(record.id)
    let deadline = ContinuousClock.now + .seconds(3)
    while model.selection != .session(record.id) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.selection == .session(record.id))
    let replacement = try #require(model.terminal)
    #expect(replacement !== original)
    #expect(platform.requests.last == .init(key: record.id, directory: record.worktree, paired: true))
    #expect(platform.requests.count == 2)
    #expect(await platform.control.paired.isEmpty)
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
                            shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil), platformFactory: platform,
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

/// An upgrade from a build with sidebar tabs says so once, while its `tabs.json` is still there,
/// and leaves the file alone; a Mac without the file is never told.
@MainActor @Test func theSidebarTabsRemovalNoticeIsToldOnceAndOnlyWhereTheOldFileIs() throws {
    let suite = "tabs-removal-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-removal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tabs.json")
    #expect(SidebarTabsRemovalNotice(defaults: defaults, tabsFile: file).take() == nil, "no old file, nothing to say")
    #expect(SidebarTabsRemovalNotice(defaults: defaults, tabsFile: nil).take() == nil)
    try Data(#"{"tabs":[],"active":null}"#.utf8).write(to: file)
    let notice = SidebarTabsRemovalNotice(defaults: defaults, tabsFile: file)
    #expect(notice.take() == "Sidebar tabs have been removed.")
    #expect(notice.take() == nil, "told once")
    #expect(SidebarTabsRemovalNotice(defaults: defaults, tabsFile: file).take() == nil, "still once after a relaunch")
    #expect(FileManager.default.fileExists(atPath: file.path), "the old file is left alone")
}

/// Each pane Terminal tab is a paired shell of its own in the session's worktree, made when the tab
/// first shows; closing the tab ends that shell, and only it.
@MainActor @Test func paneTerminalTabsRunTheirOwnShellsInTheWorktree() async throws {
    _ = NSApplication.shared
    let suite = "platform-pane-shell-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let platform = RecordingAppPlatform()
    let model = AppViewModel(creationFactory: NativeCreationFlowFactory(chooseFolder: { nil }),
                            shellFactory: NativeShellFeatureFactory(preferences: preferences, fileIcons: nil), platformFactory: platform,
                            selectionStore: TransientSidebarSelectionStore(.overview), orderStore: TransientSidebarOrderStore())
    let record = WorkspaceSession(id: "shell-session", projectId: "project", workspace: "/tmp",
        worktree: "/tmp/cascade-shell-worktree", title: "Shell session", branch: "", url: "", createdAt: nil, pinned: false)
    model.createdSession(record)
    let context = try #require(model.viewer.contexts["task:\(record.id)"])
    context.openTool(.terminal, another: true)
    context.openTool(.terminal, another: true)
    let first = WorkspaceToolTab.terminal, second = WorkspaceToolTab(.terminal, number: 2)
    await model.prepareWorkspaceShell(first, in: context)
    await model.prepareWorkspaceShell(second, in: context)
    await model.prepareWorkspaceShell(second, in: context)
    #expect(Array(platform.requests.suffix(2)) == [
        .init(key: "shell:task:\(record.id):1", directory: record.worktree, paired: true),
        .init(key: "shell:task:\(record.id):2", directory: record.worktree, paired: true),
    ], "one shell per tab, in the worktree, made once")
    let shell = try #require(model.workspaceShell(second, in: context))
    #expect(shell !== model.workspaceShell(first, in: context))
    context.close(.tool(second))
    #expect(model.workspaceShell(second, in: context) == nil)
    let deadline = ContinuousClock.now + .seconds(3)
    while await platform.control.paired.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await platform.control.paired == [["shell:task:\(record.id):2"]], "the closed tab's shell alone is ended")
    #expect(model.workspaceShell(first, in: context) != nil)
    // Reopened under the same number while its old shell is still being ended: the new tab waits
    // for that, then gets a shell of its own.
    context.close(.tool(second))
    context.openTool(.terminal, another: true)
    let requests = platform.requests.count
    await model.prepareWorkspaceShell(second, in: context)
    #expect(platform.requests.count == requests + 1 && model.workspaceShell(second, in: context) != nil)
    await model.stop()
}
