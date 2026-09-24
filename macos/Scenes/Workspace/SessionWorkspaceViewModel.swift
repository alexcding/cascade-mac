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
    var workflow: WorkflowRunViewModel?
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
    var canCreateSession = false
    /// What the toolbar calls this workspace: the session's label, the tab's title, or "Terminal".
    var title = ""
    /// A GitHub PR or Jira ticket page whose project exists: the toolbar offers Create Session.
    var offersPageSession = false
    /// Whether this panel offers New Tab at all — false for a sidebar tab, which is one page.
    var offersNewTab = true
    var editorID: String?
    var editorLabel: String?
    var launchError: String?
    var reviewBase: String?
    /// What this session's IDE is still preparing in its worktree — a package resolve a build
    /// would otherwise wait on silently.
    var warmup = IDEWarmupState()
}

enum WorkspaceOperation: Equatable {
    case openEditor, createSession(agent: SessionAgent?), openFile
    case changes, openTerminal, hookSettings, prepareChanges, toggleEditorPreview
}

@MainActor protocol WorkspaceServing: AnyObject {
    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState
    func agentCatalog(cli: String) async -> AgentCatalog?
    func agentStatus(cli: String, worktree: String, task: String) async -> AgentStatus?
}
extension WorkspaceServing {
    func agentCatalog(cli: String) async -> AgentCatalog? { nil }
    func agentStatus(cli: String, worktree: String, task: String) async -> AgentStatus? { nil }
}

@MainActor @Observable final class SessionWorkspaceViewModel {
    enum Action: Equatable {
        case operation(WorkspaceOperation), run, configureRun, remove, restart, selectTab(String), closeTab(String), reopen(String)
        case newTab, newFileTab, moveTab(String, before: String?)
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
    var workflow: WorkflowRunViewModel? {
        guard let model = state.workflow, !model.recipes.isEmpty || model.running else { return nil }
        return model
    }
    var appearance: AppAppearance { state.appearance }
    var launchError: String? { state.launchError }
    var editorID: String? { state.editorID }
    var editorLabel: String? { state.editorLabel }
    var runScheme: String {
        if let scheme = state.build?.scheme, !scheme.isEmpty { return scheme }
        if let scheme = state.project?.runScheme, !scheme.isEmpty { return scheme }
        return "Scheme"
    }
    /// The active web page's address when this workspace shows a page, for its favicon.
    var activePageURL: String? {
        guard let url = context?.activePage?.url, FaviconStore.host(of: url) != nil else { return nil }
        return url
    }
    var workspaceTitle: String {
        if context?.id == "scratch" { return "Terminal" }
        return context?.activeDocument?.title ?? context?.activePage?.title ?? "Workspace"
    }
    var terminalPrompt: String {
        context?.id == "scratch" ? "Open an interactive shell." : "Open this session’s shell in its worktree."
    }
    var showsTerminal: Bool { session != nil || context?.id == "scratch" }
    var showsChanges: Bool { session != nil && context?.pane == .diff }
    var showsPage: Bool {
        !showsTerminal || showsChanges || context?.pane == .term || context?.pane == .files || context?.pane == .simulator
    }
    var mode: WorkspaceMode {
        guard let context else { return .browser }
        if let mode = WorkspaceMode(pane: context.pane), offers(mode) { return mode }
        return offers(context.lastMode) ? context.lastMode : .browser
    }
    /// Diff needs a session, and Simulator an Xcode session's preview.
    private func offers(_ mode: WorkspaceMode) -> Bool {
        switch mode {
        case .diff: session != nil
        case .simulator: simulatorPreview != nil
        case .browser, .files: true
        }
    }
    /// The Simulator panel's model, owned by the session's build.
    var simulatorPreview: SimulatorPreviewModel? { build?.preview }
    var showsBrowser: Bool { showsPage && !showsChanges && mode == .browser }
    /// A page-only context (a sidebar tab) draws its compact tab bar in the title-bar zone: the
    /// window toolbar loses its background, icon and title, and the bar takes the toolbar's row.
    /// Only a sidebar tab: a session's workspace lives in the deck below the toolbar
    /// (`SessionWorkspaceDeck`), even while it has no session record to show a terminal for.
    var fillsTitleBar: Bool { context?.holdsOnePage == true && !showsTerminal && mode == .browser }
    var showsFiles: Bool { showsPage && !showsChanges && mode == .files }
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
    var showsModePicker: Bool { showsTerminal || context?.documents.isEmpty == false }
    func canSelectMode(_ mode: WorkspaceMode) -> Bool {
        switch mode {
        case .diff: canShowChanges
        case .simulator: simulatorPreview != nil
        case .browser, .files: true
        }
    }
    /// The picker lists Simulator only where it can show one.
    var modes: [WorkspaceMode] { WorkspaceMode.allCases.filter { $0 != .simulator || simulatorPreview != nil } }
    var showsBuildActions: Bool { session != nil && state.project?.ide == "xcode" }
    /// What this worktree's IDE is still preparing, if anything. `ready` for every IDE that
    /// prepares nothing, so the toolbar can ask without knowing which ones do.
    var warmup: IDEWarmupState { state.warmup }
    var canCreateSession: Bool { state.canCreateSession }
    var offersPageSession: Bool { session == nil && state.offersPageSession }
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
    func selectTab(_ tab: WorkspaceTab) { onAction(.selectTab(tab.id)) }
    func closeTab(_ tab: WorkspaceTab) { onAction(.closeTab(tab.id)) }
    func moveTab(_ id: String, before target: String?) { onAction(.moveTab(id, before: target)) }
    /// Only the workspace on screen may open tabs.
    var canOpenTab: Bool { active && state.canPresent }
    /// Whether the panel shows New Tab and answers ⌘T. A sidebar tab is one page, so it shows
    /// neither; `canOpenTab` still holds, so the panel's own blank filler page is unaffected.
    var offersNewTab: Bool { state.offersNewTab }
    /// Whether a page's tab shows its close button, which lets the page and its web view go. Closing
    /// a panel's last page leaves its empty state, a blank page, and a sidebar tab stays in the
    /// sidebar. A lone blank page is that empty state: closing it would only make another.
    func offersClose(_ page: BrowserPage) -> Bool {
        guard let context else { return false }
        return context.pageTabs.count > 1 || !page.controls.isBlank
    }
    /// Whether the workspace on screen is visible to the user, for taking keyboard focus.
    var isActive: Bool { active }
    func newTab() { guard canOpenTab else { return }; onAction(.newTab) }
    /// The Files panel's ＋: an empty tab whose field searches the worktree.
    func newFileTab() { guard canOpenTab else { return }; onAction(.newFileTab) }
    func selectBlankFileTab() { onAction(.selectTab(WorkspaceContext.blankFileID)) }
    func closeBlankFileTab() { onAction(.closeTab(WorkspaceContext.blankFileID)) }
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
        state.buildTerminal?.presentation.style = state.terminalStyle
    }
    func documentStateChanged() {
        let state = state
        let visible = active && context?.restoring == false
        let reviewing = visible && showsChanges && state.connected
        if presentedDiff !== state.diff { presentedDiff?.presentation.active = false }
        if presentedHistory !== state.history { presentedHistory?.presentation.active = false }
        presentedDiff = state.diff; presentedHistory = state.history
        state.diff?.presentation = .init(active: reviewing && context?.reviewSection == .changes,
                                         appearance: state.appearance, font: state.documentFont)
        state.history?.presentation = .init(active: reviewing && context?.reviewSection == .history,
                                            appearance: state.appearance, font: state.documentFont)
        // On any pane: switching back to the Simulator is instant, and a hidden session streams nothing.
        state.build?.preview?.active = visible
        // Once each, not per page or document: every one of these rebuilds the workspace state.
        let shownPage = visible && showsBrowser ? context?.activePage : nil
        let shownDocument = visible && showsFiles ? context?.activeDocument : nil
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
    /// `agent` nil starts the default agent — the button's click; the dropdown names one.
    func createSession(agent: SessionAgent? = nil) { if canCreateSession { perform(.createSession(agent: agent)) } }
    func openFile() { perform(.openFile) }
    func toggleChanges() { if canShowChanges { perform(.changes) } }
    func selectMode(_ mode: WorkspaceMode) {
        guard let context, canSelectMode(mode) else { return }
        switch mode {
        case .diff: if context.pane != .diff { perform(.changes) }
        case .browser, .files, .simulator: context.setPane(mode.pane)
        }
    }
    func run() { if canRun { onAction(.run) } }
    func configureRun() { if canRun { onAction(.configureRun) } }
    func remove() { if canRemove { onAction(.remove) } }
    func restart() { if canRestart { onAction(.restart) } }
    func openTerminal() { if showsTerminal { perform(.openTerminal) } }
    /// Types a slash command into the running agent. Mid-turn input would queue behind the
    /// turn, so the controls wait for the agent to go idle.
    func compactAgent() { if let driver = agentDriver { typeToAgent([.line(driver.compactCommand)]) } }
    func clearAgent() { if let driver = agentDriver { typeToAgent([.line(driver.clearCommand)]) } }
    func isRunning(_ selection: AgentSelection) -> Bool {
        guard let running = agentSelection else { return false }
        return agentCatalog.model(selection.model)?.id == (agentCatalog.model(running.model)?.id ?? running.model) && selection.effort == running.effort
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
            agentCommandError = "\(selection.model) is not a model this CLI lists."; return
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
    func setContextPresented(_ presented: Bool) {
        guard canToggleContext, let context else { return }
        if presented { context.setPane(context.lastMode.pane) } else { context.setPane(.off) }
    }
    func reopen(_ visit: WorkspaceVisit) {
        guard active, state.canPresent else { return }
        onAction(.reopen(visit.id))
    }
    /// The preview beside the code is one app-wide preference, so the button reports out.
    func toggleEditorPreview() { perform(.toggleEditorPreview) }
    private func perform(_ operation: WorkspaceOperation) {
        guard context != nil else { return }
        onAction(.operation(operation))
    }
}
