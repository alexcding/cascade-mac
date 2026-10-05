import Foundation
import Observation

@MainActor struct SessionWorkspaceState {
    var session: WorkspaceSession?
    var project: Project?
    var terminal: TerminalSession?
    var buildTerminal: TerminalSession?
    var build: BuildWorkspaceViewModel?
    var history: GitHistoryViewModel?
    var diff: DiffViewModel?
    var appearance: AppAppearance = .system
    var documentFont = CodeFont(size: 12)
    var editorStyle = EditorStyle()
    var terminalStyle = TerminalStyle()
    var connected = false
    var changingSession = false
    /// A removal in flight for this session. Distinct from `changingSession`: removal tears the
    /// terminal down and never brings one back, so the pane must not claim one is opening.
    var removingSession = false
    var openingExternal = false
    var canPresent = false
    /// What the toolbar calls this workspace: the session's label, or "Terminal".
    var title = ""
    var editorID: String?
    var editorLabel: String?
    var launchError: String?
    var reviewBase: String?
    /// What this session's IDE is still preparing in its worktree — a package resolve a build
    /// would otherwise wait on silently.
    var warmup = IDEWarmupState()
}

enum WorkspaceOperation: Equatable {
    case openEditor, openFile
    case changes, openTerminal, hookSettings, prepareChanges
}

/// Where a terminal's approval requests go while its chat is on screen.
struct PermissionWatcher {
    /// The request to show, the oldest still waiting, or nil for none.
    let show: (AgentPermissionPrompt?) -> Void
    /// A request the chat held fell back to the terminal's own prompt, which the chat covers.
    let movedToTerminal: () -> Void
}

/// What names a terminal session's conversation as a chat thread (`GET /api/agent/transcript`
/// with `format=thread`).
struct TranscriptThreadQuery: Equatable, Sendable {
    let cli: String
    let worktree: String
    /// The conversation the agent is in, when known.
    var conversation: String?
    /// The terminal the agent runs in, whose waiting approvals the thread shows.
    var runID: String?
    let threadID: String
    let projectID: String
}

@MainActor protocol WorkspaceServing: AnyObject {
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState
    func agentCatalog(cli: String) async -> AgentCatalog?
    func agentStatus(cli: String, worktree: String, task: String) async -> AgentStatus?
    /// `conversation` is the one the agent is in, when known: its transcript alone is read.
    func agentTranscript(cli: String, worktree: String, since: String?, conversation: String?) async throws -> AgentTranscript
    /// The same conversation as a read-only chat thread, `{revision, snapshot}`, for the chat page:
    /// under `threadID` and `projectID`, with the approvals the terminal `runID` waits on.
    func agentTranscriptThread(_ query: TranscriptThreadQuery, since: String?) async throws -> JSONValue
    /// The CLI's slash commands in this worktree, for the chat's `/` suggestions.
    func agentCommands(cli: String, worktree: String) async -> [AgentCommand]
    /// Files of the worktree matching a query, best first, for the chat's `@` suggestions.
    func worktreeFiles(_ worktree: String, matching query: String) async -> [String]
    func watchPermissions(runID: String, _ watcher: PermissionWatcher)
    func unwatchPermissions(runID: String)
    func answerPermission(_ id: String, decision: String) async throws
    /// One of the chat page's reads of a folder (`ChatFileAccess.folderMethods`), through the chat
    /// backend, for a terminal session's read-only chat.
    func chatFolderRead(_ method: String, params: JSONValue) async throws -> JSONValue
}
extension WorkspaceServing {
    func watchPermissions(runID: String, _ watcher: PermissionWatcher) {}
    func unwatchPermissions(runID: String) {}
    func answerPermission(_ id: String, decision: String) async throws {}
    func chatFolderRead(_ method: String, params: JSONValue) async throws -> JSONValue { throw TranscriptPageBackend.unavailable }
    func agentCatalog(cli: String) async -> AgentCatalog? { nil }
    func agentStatus(cli: String, worktree: String, task: String) async -> AgentStatus? { nil }
    func agentTranscript(cli: String, worktree: String, since: String?, conversation: String?) async throws -> AgentTranscript {
        AgentTranscript(revision: "", turns: [], hooks: nil)
    }
    func agentTranscriptThread(_ query: TranscriptThreadQuery, since: String?) async throws -> JSONValue {
        ["revision": "", "snapshot": nil]
    }
    func agentCommands(cli: String, worktree: String) async -> [AgentCommand] { [] }
    func worktreeFiles(_ worktree: String, matching query: String) async -> [String] { [] }
}

@MainActor @Observable final class SessionWorkspaceViewModel {
    enum Action: Equatable {
        case operation(WorkspaceOperation), run, configureRun, remove, restart, selectTab(String), closeTab(String), reopen(String)
        case newTab, moveTab(String, before: String?), fork
    }
    struct ReviewInputs: Equatable {
        let pane: WorkspacePane?
        let section: ReviewSection?
        let connected: Bool
        let base: String?
        let sessionID: String?
    }
    @ObservationIgnored private weak var context: WorkspaceContext?
    @ObservationIgnored private weak var service: (any WorkspaceServing)?
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private var previousReviewInputs: ReviewInputs?
    @ObservationIgnored private weak var presentedDiff: DiffViewModel?
    @ObservationIgnored private weak var presentedHistory: GitHistoryViewModel?
    private(set) var active = false {
        didSet { if oldValue != active { reviewStateChanged(force: true) } }
    }

    init(context: WorkspaceContext, service: any WorkspaceServing) {
        self.context = context; self.service = service
    }
    private var state: SessionWorkspaceState {
        guard let context, let service else { return SessionWorkspaceState() }
        return service.workspaceState(in: context)
    }
    var session: WorkspaceSession? { state.session }
    var title: String { state.title }
    var terminal: TerminalSession? { state.terminal }
    var removingSession: Bool { state.removingSession }
    var buildTerminal: TerminalSession? { state.buildTerminal }
    var build: BuildWorkspaceViewModel? { state.build }
    var history: GitHistoryViewModel? { state.history }
    var diff: DiffViewModel? { state.diff }
    var appearance: AppAppearance { state.appearance }
    var launchError: String? { state.launchError }
    var editorID: String? { state.editorID }
    var editorLabel: String? { state.editorLabel }
    var runScheme: String {
        if let scheme = state.build?.scheme, !scheme.isEmpty { return scheme }
        if let scheme = state.project?.runScheme, !scheme.isEmpty { return scheme }
        return String(localized: "Scheme")
    }
    /// The active web page's address when this workspace shows a page, for its favicon.
    var activePageURL: String? {
        guard let url = context?.activePage?.url, FaviconStore.host(of: url) != nil else { return nil }
        return url
    }
    var workspaceTitle: String {
        if context?.id == "scratch" { return String(localized: "Terminal") }
        return context?.activeDocument?.title ?? context?.activePage?.title ?? String(localized: "Workspace")
    }
    var terminalPrompt: String {
        context?.id == "scratch" ? String(localized: "Open an interactive shell.") : String(localized: "Open this session’s shell in its worktree.")
    }
    var showsTerminal: Bool { session != nil || context?.id == "scratch" }
    var showsChanges: Bool { session != nil && context?.pane == .diff }
    var showsPage: Bool {
        !showsTerminal || showsChanges || context?.pane == .term || context?.pane == .simulator
    }
    /// What the pane shows: its pages and files (`term`), Diff or Simulator, never `off`. A pane
    /// this workspace cannot show falls back to the last one it can, then to the pages and files.
    var shownPane: WorkspacePane {
        guard let context else { return .term }
        if offers(context.pane) { return context.pane }
        return offers(context.lastPane) ? context.lastPane : .term
    }
    /// Diff needs a session, and Simulator an Xcode session's preview.
    private func offers(_ pane: WorkspacePane) -> Bool {
        switch pane {
        case .diff: session != nil
        case .simulator: simulatorPreview != nil
        case .term: true
        case .off: false
        }
    }
    /// The Simulator panel's model, owned by the session's build.
    var simulatorPreview: SimulatorPreviewModel? { build?.preview }
    var showsBrowser: Bool { showsPage && !showsChanges && shownPane == .term }
    /// Beside a terminal the context pane is the window's inspector column, with its own section of
    /// the toolbar tracking the divider (`MainSplitViewController`).
    var showsInspector: Bool { showsTerminal && showsPage }
    /// Keyboard highlight in the address suggestions; nil means Enter submits the typed text. Here
    /// rather than in the bar, which the list it highlights is drawn apart from.
    var addressHighlight: Int?
    /// The session's agent CLI; a scratch shell or a shell-only session has none, and no footer.
    var agentDriver: (any AgentDriver)? { session.flatMap { SessionAgent(rawValue: $0.cli ?? "")?.driver } }
    var canSendAgentCommand: Bool { terminal?.ready == true && terminal?.agentBusy == false }
    private(set) var agentCatalog = AgentCatalog()
    private(set) var agentStatus: AgentStatus?
    private(set) var agentCommandError: String?
    /// What the footer last asked for, shown until the agent's own status says otherwise: Claude
    /// only records a new effort with its next turn, and Codex's picker takes a moment to walk.
    @ObservationIgnored private var reportedWhenSwitched: AgentSelection?
    @ObservationIgnored private var switchedAt = Date.distantPast
    private(set) var pendingSelection: AgentSelection?
    /// What the agent's own status says it is running.
    private var reportedSelection: AgentSelection? {
        agentStatus.flatMap { status in status.model.map { AgentSelection(model: $0, effort: status.effort) } }
    }
    /// What the agent is running, as far as anyone can tell: a pending switch, else its status.
    var agentSelection: AgentSelection? { pendingSelection ?? reportedSelection }
    /// Changes whenever the agent finishes a turn, which is when the readout goes stale.
    var agentStatusTrigger: String {
        "\(session?.id ?? "")|\(terminal?.agentTurns.revision ?? 0)|\(terminal?.agentBusy == true)"
    }
    /// The view task supplies visibility and cancellation; the pace stays here. Both CLIs write
    /// after every step of a turn, so a busy agent is read every couple of seconds. An idle one
    /// still gets a slow look, for a turn no hook reported.
    func watchAgentStatus() async {
        if agentCatalog.models.isEmpty, let driver = agentDriver, let value = await service?.agentCatalog(cli: driver.cli),
           context != nil { agentCatalog = value }
        while !Task.isCancelled, context != nil {
            await refreshAgentStatus()
            do { try await Task.sleep(for: .seconds(terminal?.agentBusy == true ? 2 : 5)) } catch { return }
        }
    }
    private func refreshAgentStatus() async {
        guard context != nil, let service, let driver = agentDriver, let session else { agentStatus = nil; return }
        let value = await service.agentStatus(cli: driver.cli, worktree: session.worktree, task: session.id)
        guard !Task.isCancelled, context != nil else { return }
        agentStatus = value
        // Only the model or effort moving answers a switch; the token count moves on its own. A
        // switch that never lands (keys dropped in a picker) must not be claimed for ever either.
        if pendingSelection != nil, reportedSelection != reportedWhenSwitched || Date().timeIntervalSince(switchedAt) > 20 {
            pendingSelection = nil
        }
    }
    var showsBuildActions: Bool { session != nil && state.project?.ide == "xcode" }
    /// What this worktree's IDE is still preparing, if anything. `ready` for every IDE that
    /// prepares nothing, so the toolbar can ask without knowing which ones do.
    var warmup: IDEWarmupState { state.warmup }
    var canOpenExternal: Bool { session != nil && !state.openingExternal && !state.changingSession }
    var canShowChanges: Bool { session != nil && state.connected }
    var canRun: Bool { showsBuildActions && state.connected && state.canPresent && !state.changingSession }
    var canRemove: Bool { session != nil && state.connected && state.canPresent && !state.changingSession }
    var canRestart: Bool { session != nil && state.canPresent && !state.changingSession }
    var canToggleContext: Bool { showsTerminal && context != nil }
    var reviewInputs: ReviewInputs {
        .init(pane: context?.pane, section: context?.reviewSection, connected: state.connected, base: state.reviewBase, sessionID: state.session?.id)
    }

    func setActive(_ value: Bool) { active = value }
    /// Diff's tab goes through the app, which loads the changes before showing them; with no
    /// backend to load them from it is selected as any tab is, and shows why it is empty.
    func selectTab(_ tab: WorkspaceTab) {
        if case .tool(.changes) = tab, !showsChanges, canShowChanges { toggleChanges(); return }
        onAction(.selectTab(tab.id))
    }
    func closeTab(_ tab: WorkspaceTab) { onAction(.closeTab(tab.id)) }
    func moveTab(_ id: String, before target: String?) { onAction(.moveTab(id, before: target)) }
    /// Only the workspace on screen may open tabs.
    var canOpenTab: Bool { active && state.canPresent }
    /// Whether a page's tab shows its close button, which lets the page and its web view go. Closing
    /// a panel's last tab leaves its empty state, a blank page. A lone blank page is that empty
    /// state: closing it would only make another.
    func offersClose(_ page: BrowserPage) -> Bool {
        guard let context else { return false }
        return context.tabs.count > 1 || !page.controls.isBlank
    }
    /// Whether the workspace on screen is visible to the user, for taking keyboard focus.
    var isActive: Bool { active }
    func newTab() { guard canOpenTab else { return }; onAction(.newTab) }
    func reviewStateChanged(force: Bool = false) {
        let inputs = reviewInputs
        if force || previousReviewInputs != inputs {
            previousReviewInputs = inputs
            prepareChanges()
        }
        documentStateChanged()
        terminalStateChanged()
    }
    /// Which terminal is on screen is the view's `if`; the model only keeps their style current.
    func terminalStateChanged() {
        let state = state
        state.terminal?.presentation.style = state.terminalStyle
        // The build log hangs in a toolbar popover, off the window's backdrop: it keeps its theme's
        // own background whether or not the window is translucent.
        var buildStyle = state.terminalStyle
        buildStyle.backgroundOpacity = 1
        state.buildTerminal?.presentation.style = buildStyle
    }
    func documentStateChanged() {
        let state = state
        let visible = active && context != nil
        let reviewing = visible && showsChanges && state.connected
        if presentedDiff !== state.diff { presentedDiff?.presentation.active = false; presentedDiff?.reviewing = false }
        if presentedHistory !== state.history { presentedHistory?.presentation.active = false }
        presentedDiff = state.diff; presentedHistory = state.history
        state.diff?.presentation = .init(active: reviewing && context?.reviewSection == .changes,
                                         appearance: state.appearance, font: state.documentFont)
        state.diff?.reviewing = reviewing
        state.history?.presentation = .init(active: reviewing && context?.reviewSection == .history,
                                            appearance: state.appearance, font: state.documentFont)
        // On any pane: switching back to the Simulator is instant, and a hidden session streams nothing.
        state.build?.preview?.active = visible
        // Once each, not per page or document: every one of these rebuilds the workspace state.
        let shownPage = visible && showsBrowser ? context?.activePage : nil
        let shownDocument = visible && showsBrowser ? context?.activeDocument : nil
        for page in context?.pages ?? [] {
            let activePage = page === shownPage
            page.controls.active = activePage
            page.dialogs.active = activePage
        }
        for document in context?.documents ?? [] {
            document.presentation = .init(active: document === shownDocument,
                                           appearance: state.appearance, font: state.documentFont, editor: state.editorStyle)
        }
    }
    func prepareChanges() { if active && showsChanges { perform(.prepareChanges) } }
    func openEditor() { if canOpenExternal && editorLabel != nil { perform(.openEditor) } }
    func openFile() { perform(.openFile) }
    func toggleChanges() { if canShowChanges { perform(.changes) } }
    /// What a session's blank tab offers to open: its worktree's Files explorer, its changes, its
    /// agent's Live diagram, and the Simulator while a build has one. A web page is the blank tab
    /// itself.
    func startPageTools() -> [StartPageTool] {
        guard let context, listsWorktree else { return [] }
        // One tab of each tool: one already open is in the strip, not offered again. But for Files,
        // offered every time: each pick opens another tab of it, as a web page gets another.
        let open = Set(context.tools)
        var tools: [StartPageTool] = []
        tools.append(.init(id: "files", title: String(localized: "Files"), symbol: "folder") { [weak context] in
            context?.openTool(.files, replacingBlank: true, another: true)
        })
        if canShowChanges, !open.contains(.changes) {
            tools.append(.init(id: "diff", title: WorkspaceTool.changes.title, symbol: WorkspaceTool.changes.symbol) { [weak self, weak context] in
                // As the other tools do, Diff takes the blank tab's place once it opens.
                let blank = context?.replaceableBlank
                self?.toggleChanges()
                if let blank, context?.activeTool == .changes { context?.close(.page(blank)) }
            })
        }
        if canShowLive, !open.contains(.live) {
            tools.append(.init(id: "live", title: WorkspaceTool.live.title, symbol: WorkspaceTool.live.symbol) { [weak context] in
                context?.openTool(.live, replacingBlank: true)
            })
        }
        if simulatorPreview != nil, !open.contains(.simulator) {
            tools.append(.init(id: "simulator", title: WorkspaceTool.simulator.title, symbol: WorkspaceTool.simulator.symbol) { [weak context] in
                context?.openTool(.simulator, replacingBlank: true)
            })
        }
        return tools
    }
    /// Whether there is a worktree for the Files picker to list. The scratch Terminal has none, but
    /// can still open files, from the terminal's links.
    var listsWorktree: Bool { session?.worktree.isEmpty == false }
    /// The Simulator's run is over: its tab has nothing left to show, so the pane goes back to the
    /// page or file shown before it rather than sitting blank with no tabs.
    func leaveEndedSimulator() {
        guard let context, simulatorPreview == nil, context.tools.contains(.simulator) else { return }
        if context.activeTool == .simulator { context.showPages() }
        context.close(.tool(.simulator))
    }
    /// A link from the chat opens in this session's browser, beside the chat, and brings it in.
    private func openInBrowser(_ url: URL) -> Bool {
        guard let context, context.open(url.absoluteString) != nil else { return false }
        context.setPane(.term)
        return true
    }
    /// A file the chat names opens in this session's pane, beside the chat.
    private func openFileFromChat(_ path: String, line: Int?) {
        guard let context, context.openFile(path, line: max(line ?? 1, 1)) != nil else { return }
        context.setPane(.term)
    }
    func run() { if canRun { onAction(.run) } }
    func configureRun() { if canRun { onAction(.configureRun) } }
    func remove() { if canRemove { onAction(.remove) } }
    func restart() { if canRestart { onAction(.restart) } }
    /// The chat's Fork Session: a new session carrying this one's conversation on.
    func fork() { if canRestart, agentDriver != nil { onAction(.fork) } }
    func openTerminal() { if showsTerminal { perform(.openTerminal) } }
    /// Types a slash command into the running agent. Mid-turn input would queue behind the
    /// turn, so the controls wait for the agent to go idle.
    func compactAgent() { if let driver = agentDriver { typeToAgent([.line(driver.compactCommand)]) } }
    func clearAgent() { if let driver = agentDriver { typeToAgent([.line(driver.clearCommand)]) } }
    func isRunning(_ selection: AgentSelection) -> Bool {
        guard let running = agentSelection else { return false }
        return agentCatalog.selection(selection, isRunning: running, among: agentPresets)
    }
    /// The model menu's presets, in menu order. The toolbar owns their storage and hands the
    /// resolved list over, so the Next Model command and the menu cannot disagree.
    var agentPresets: [AgentPreset] = []
    var canCycleAgentPreset: Bool { context != nil && canSendAgentCommand && agentPresets.count > 1 }
    /// The next or previous preset in menu order, wrapping. From a model no preset names, the first.
    func cycleAgentPreset(_ direction: Int) {
        guard canCycleAgentPreset else { return }
        let presets = agentPresets
        let next = presets.firstIndex { isRunning($0.selection) }.map { ($0 + direction + presets.count) % presets.count } ?? 0
        switchAgent(to: presets[next].selection)
    }
    /// Switches the agent inside its running conversation. The driver knows what its CLI wants
    /// typed; this only carries it out.
    func switchAgent(to selection: AgentSelection) {
        guard context != nil, canSendAgentCommand, let driver = agentDriver else { return }
        guard let model = agentCatalog.model(selection.model) else {
            agentCommandError = String(localized: "\(selection.model) is not a model this CLI lists."); return
        }
        let effort = model.efforts.contains { $0.id == selection.effort } ? selection.effort : nil
        do {
            let inputs = try driver.switchInputs(to: model, effort: effort, in: agentCatalog)
            reportedWhenSwitched = reportedSelection
            switchedAt = Date()
            pendingSelection = AgentSelection(model: model.id, effort: effort ?? model.defaultEffort)
            typeToAgent(inputs)
        } catch { agentCommandError = error.localizedDescription }
    }
    private func typeToAgent(_ inputs: [AgentInput]) {
        guard context != nil, canSendAgentCommand, let terminal else { return }
        agentCommandError = nil
        Task { [weak self] in
            do { try await terminal.submitToAgent(inputs) } catch {
                self?.agentCommandError = error.localizedDescription
                self?.pendingSelection = nil
            }
        }
    }
    func openHookSettings() { perform(.hookSettings) }
    func stopBuild() async { await build?.stop() }
    func toggleContext() { setContextPresented(!showsPage) }

    // MARK: Live

    /// The Live tab's model, made when the tab is first shown and kept while the workspace lives.
    private(set) var live: LivePanelModel?
    var canShowLive: Bool { session?.cli != nil }
    /// The Live tab on screen: this workspace shown, its pane open on the tab.
    private var showsLive: Bool { active && showsBrowser && context?.activeTool == .live }

    /// The effort the agent runs at: its name, and how far up its model's efforts it is, 0 to 1,
    /// from the catalog's own order — 0 for one the catalog does not list, as `auto` is not.
    var agentEffort: (name: String, fraction: Double)? {
        guard let effort = agentSelection?.effort, !effort.isEmpty else { return nil }
        let efforts = agentCatalog.model(agentSelection?.model)?.efforts ?? []
        guard let index = efforts.firstIndex(where: { $0.id == effort }) else { return (effort, 0) }
        return (efforts[index].name, Double(index + 1) / Double(efforts.count))
    }

    /// What the session's agent is doing, as its terminal's hooks report it.
    enum AgentRunState { case notRunning, working, waiting, idle }
    var agentRunState: AgentRunState {
        guard let turns = terminal?.agentTurns else { return .notRunning }
        if turns.needsInput { return .waiting }
        return turns.busy ? .working : .idle
    }

    /// Made by the tab as it appears, and again should the session arrive after it: a tab restored
    /// from a snapshot needs one as much as a new one.
    func prepareLive() {
        guard live == nil, context != nil, canShowLive, let session, let cli = session.cli else { return }
        let worktree = session.worktree
        live = LivePanelModel(
            load: { [weak self] since in
                guard let service = self?.service else { return AgentTranscript(revision: "", turns: [], hooks: nil) }
                return try await service.agentTranscript(cli: cli, worktree: worktree, since: since,
                                                         conversation: self?.agentConversation)
            },
            busy: { [weak self] in self?.terminal?.agentBusy == true },
            visible: { [weak self] in self?.showsLive == true },
            feed: { [weak self] in self?.terminal?.agentTurns.tools.heard(in: self?.agentConversation) ?? .init() })
    }

    // MARK: Chat overlay (prototype)

    /// The chat drawn over the terminal, made on first show and kept while the workspace lives.
    private(set) var chat: TranscriptChatModel?
    private(set) var showsChat = false
    var canShowChat: Bool { session?.cli != nil && terminal != nil }
    /// In Chat: the chat is what is on screen, over the terminal.
    var chatCoversTerminal: Bool { showsChat && chat != nil }

    /// Each session keeps the mode it was left in, across relaunches; Terminal until it is changed.
    private static func chatModeKey(_ sessionID: String) -> String { "workspace.chatMode.\(sessionID)" }
    /// Whether the session opens in Chat, for whoever hands it the keyboard.
    static func opensInChat(sessionID: String) -> Bool { UserDefaults.standard.bool(forKey: chatModeKey(sessionID)) }

    /// Called when the terminal appears, so a session left in Chat opens in Chat.
    func restoreChatMode() {
        guard let session, Self.opensInChat(sessionID: session.id) else { return }
        setChatShown(true)
    }

    /// The keyboard goes to what is on screen: the chat's message field, or the terminal.
    func focusAgent() {
        if chatCoversTerminal { chat?.requestFocus() } else { terminal?.surface.requestFocus() }
    }

    func toggleChat() { setChatShown(!showsChat) }

    /// The conversation the terminal's agent is in: as its hooks last said, or as it was launched.
    /// Read on every poll: `/clear` starts a new one under the same agent.
    private var agentConversation: String? {
        [terminal?.agentTurns.sessionID, session?.sessionId].compactMap { $0 }.first { !$0.isEmpty }
    }

    func setChatShown(_ shown: Bool) {
        guard canShowChat, let session, let cli = session.cli else { return }
        UserDefaults.standard.set(shown, forKey: Self.chatModeKey(session.id))
        if shown, chat == nil {
            let worktree = session.worktree
            chat = TranscriptChatModel(
                agentName: SessionAgent(rawValue: cli)?.label ?? cli.capitalized,
                load: { [weak self] since in
                    guard let service = self?.service else { return AgentTranscript(revision: "", turns: [], hooks: nil) }
                    return try await service.agentTranscript(cli: cli, worktree: worktree, since: since,
                                                             conversation: self?.agentConversation)
                },
                deliver: { [weak self] text, files, clear in
                    guard let terminal = self?.terminal else { throw BackendError.operation(String(localized: "The terminal is not open.")) }
                    // A message ending in an @ mention gets a space, which closes the file list the
                    // CLI opened for it: Enter on that list picks a file instead of sending.
                    let text = ChatCompletion.endsInMention(text) ? text + " " : text
                    // A command must open the line, so its files follow it, as its arguments. Any
                    // other message has them go first, pasted as a drop onto the terminal pastes
                    // them, so the agent attaches them before the message is typed after them.
                    let command = text.hasPrefix("/")
                    let joined = files.map(\.path).joined(separator: " ")
                    // Everything is checked before anything is typed, so a message the terminal
                    // refuses leaves nothing half-written in the agent's prompt.
                    let paths = try files.isEmpty ? nil : TerminalSession.paste(command ? " " + joined : joined + " ")
                    let pasted = try text.isEmpty ? nil : TerminalSession.paste(text)
                    let multiline = text.contains("\n")
                    if let paths, !command {
                        try await clear()
                        try await terminal.writeAgentInput(paths)
                        try await Task.sleep(for: .milliseconds(600))
                    }
                    // One line is typed like the agent controls type a command. Several need a
                    // bracketed paste, and Claude Code takes an Enter that follows a paste closely
                    // as part of it, so that Enter waits until the paste has settled.
                    if let pasted {
                        try await clear()
                        try await terminal.writeAgentInput(multiline ? pasted : text)
                        try await Task.sleep(for: .milliseconds(multiline ? 600 : 60))
                    }
                    if let paths, command {
                        try await clear()
                        try await terminal.writeAgentInput(paths)
                        try await Task.sleep(for: .milliseconds(600))
                    }
                    try await clear()
                    try await terminal.writeAgentInput("\r")
                },
                completions: .init(
                    commands: { [weak self] in await self?.service?.agentCommands(cli: cli, worktree: worktree) ?? [] },
                    files: { [weak self] query in await self?.service?.worktreeFiles(worktree, matching: query) ?? [] }),
                permissions: .init(
                    // Read on every poll: a restarted session's terminal runs under a new id.
                    runID: { [weak self] in self?.terminal?.termID },
                    watch: { [weak self] runID, watcher in self?.service?.watchPermissions(runID: runID, watcher) },
                    unwatch: { [weak self] runID in self?.service?.unwatchPermissions(runID: runID) },
                    answer: { [weak self] id, decision in
                        guard let service = self?.service else { throw BackendError.operation(String(localized: "The workspace is closed.")) }
                        try await service.answerPermission(id, decision: decision)
                    }),
                thread: .init(
                    context: ChatPageContext(threadId: "transcript-\(session.id)", projectId: session.projectId, cwd: worktree,
                                             projectName: state.project?.name ?? "", readOnly: true),
                    read: { [weak self] since in
                        guard let self, let service = self.service else { throw BackendError.operation(String(localized: "The workspace is closed.")) }
                        // Read on every poll, as the transcript is: a restart or `/clear` changes them.
                        let query = TranscriptThreadQuery(cli: cli, worktree: worktree, conversation: agentConversation,
                                                          runID: terminal?.termID, threadID: "transcript-\(session.id)",
                                                          projectID: session.projectId)
                        return try await service.agentTranscriptThread(query, since: since)
                    },
                    files: { @MainActor [weak self] method, params in
                        guard let service = self?.service else { throw TranscriptPageBackend.unavailable }
                        return try await service.chatFolderRead(method, params: params)
                    }),
                showTerminal: { [weak self] in self?.setChatShown(false) },
                openLink: { [weak self] url in self?.openInBrowser(url) ?? false },
                openFile: { [weak self] path, line in self?.openFileFromChat(path, line: line) },
                fork: { [weak self] in self?.fork() })
        }
        defer {
            // Set on every call: a restarted session's terminal is a new one, and must be covered too.
            terminal?.coveredByChat = chatCoversTerminal
        }
        guard showsChat != shown else { return }
        showsChat = shown
        // A switch by hand takes the keyboard with it; the terminal would otherwise keep it hidden.
        if active { focusAgent() }
    }

    /// The workspace owns its chat, so its chat goes with it.
    isolated deinit { chat?.retire(); live?.retire() }
    func setContextPresented(_ presented: Bool) {
        guard canToggleContext, let context else { return }
        guard presented else { context.setPane(.off); return }
        let shown = presentable(context.lastPane)
        if shown == .term { context.showPages() } else { context.setPane(shown) }
    }
    /// `pane` if this workspace can still show it, else the pages: a Simulator whose run has ended,
    /// or Changes without a session, would open a tab with nothing in it.
    func presentable(_ pane: WorkspacePane) -> WorkspacePane { offers(pane) ? pane : .term }
    func reopen(_ visit: WorkspaceVisit) {
        guard active, state.canPresent else { return }
        onAction(.reopen(visit.id))
    }
    private func perform(_ operation: WorkspaceOperation) {
        guard context != nil else { return }
        onAction(.operation(operation))
    }
}
