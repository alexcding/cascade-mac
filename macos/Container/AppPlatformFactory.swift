import Foundation

struct AppTerminalRequest: Equatable {
    let key: String
    let directory: String
    let paired: Bool
}

protocol TerminalRuntimeControlling: Sendable {
    func stopPaired(keys: Set<String>) async throws
    func stopExisting() async throws
}

struct NativeTerminalRuntimeControl: TerminalRuntimeControlling {
    let configuration: @Sendable () throws -> PtydConfiguration
    func stopPaired(keys: Set<String>) async throws {
        try await PtydHost(configuration: configuration()).stopPaired(keys: keys)
    }
    func stopExisting() async throws {
        try await PtydHost(configuration: configuration()).stopExisting()
    }
}

@MainActor protocol AppPlatformFactory {
    var homeDirectory: String { get }
    func viewer(dialogs: BrowserDialogCoordinator,
                documents: any DocumentFeatureFactory, close: EditorCloseCoordinator) -> ViewerStore
    func workspaceLauncher() -> WorkspaceLaunchViewModel
    func terminal(_ request: AppTerminalRequest) -> TerminalSession
    func detachedShell(_ request: AppTerminalRequest) -> DetachedShell
    func terminalControl() -> any TerminalRuntimeControlling
    func workflowTerminal(_ terminal: TerminalSession, cli: WorkflowCLI, sessionID: String?) async throws -> any WorkflowTerminal
    func resources(api: APIClient?) -> any ResourceUsageService
    func pageActions(open: @escaping (OpenPageRequest) async throws -> Void,
                     session: @escaping (OpenPageRequest) -> PageSessionMark?) -> any PageActionServing
}

extension AppPlatformFactory {
    func pageActions(open: @escaping (OpenPageRequest) async throws -> Void) -> any PageActionServing {
        pageActions(open: open, session: { _ in nil })
    }
}

@MainActor struct NativeAppPlatformFactory: AppPlatformFactory {
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var configuration: @Sendable () throws -> PtydConfiguration = { try .current() }
    var launcher: any WorkspaceCommandLauncher = NativeWorkspaceCommandLauncher()

    func viewer(dialogs: BrowserDialogCoordinator,
                documents: any DocumentFeatureFactory, close: EditorCloseCoordinator) -> ViewerStore {
        let directory = try? configuration().directory
        return ViewerStore(cacheURL: directory?.appendingPathComponent("page-tabs.json"),
                    browserHistory: BrowserHistoryStore(fileURL: directory?.appendingPathComponent("browser-history.json")),
                    browserBookmarks: BrowserBookmarkStore(fileURL: directory?.appendingPathComponent("browser-bookmarks.json")),
                    pageFactory: BrowserPageFactory(dialogs: dialogs, adBlocker: .shared),
                    documentFactory: documents, closeCoordinator: close)
    }
    func workspaceLauncher() -> WorkspaceLaunchViewModel { WorkspaceLaunchViewModel(launcher: launcher) }
    func terminal(_ request: AppTerminalRequest) -> TerminalSession {
        TerminalSession(pairKey: request.key, cwd: request.directory, paired: request.paired, configurationProvider: configuration)
    }
    func detachedShell(_ request: AppTerminalRequest) -> DetachedShell {
        DetachedShell(pairKey: request.key, cwd: request.directory, configurationProvider: configuration)
    }
    func terminalControl() -> any TerminalRuntimeControlling { NativeTerminalRuntimeControl(configuration: configuration) }
    func workflowTerminal(_ terminal: TerminalSession, cli: WorkflowCLI, sessionID: String?) async throws -> any WorkflowTerminal {
        try await NativeWorkflowTerminal(terminal: terminal, cli: cli, sessionID: sessionID)
    }
    func resources(api: APIClient?) -> any ResourceUsageService {
        NativeResourceUsageService(api: api, pty: try? configuration())
    }
    func pageActions(open: @escaping (OpenPageRequest) async throws -> Void,
                     session: @escaping (OpenPageRequest) -> PageSessionMark?) -> any PageActionServing {
        NativePageActionService(open: open, session: session)
    }
}
