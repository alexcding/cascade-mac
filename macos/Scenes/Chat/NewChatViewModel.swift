import Foundation
import Observation

/// New Chat: which agent, which of its models, and where it works. A project's chat works in the
/// project's folder; a standalone one in a folder the person picked, which they can change here.
/// New Task's Chat side may start a project's chat with what one of its sessions' agents knows: the
/// chat then works in that session's worktree, the one place the backend takes that knowledge for,
/// and is listed under the project as any of its chats.
/// The chat starts asking before every tool call (`approval-required`), and is titled "New Chat"
/// until the backend titles it from the first message.
@MainActor @Observable final class NewChatViewModel {
    enum Action: Equatable {
        /// The chat exists; its shell as far as the app knows it until the backend's arrives.
        case created(ChatThreadShell)
    }

    struct Agent: Identifiable, Equatable {
        let cli: String
        let provider: String
        let name: String
        /// Installed and enabled: a chat can start on it.
        let usable: Bool
        /// Why not, when it is not.
        let note: String?
        var id: String { cli }
    }

    /// The session a chat started in its pane may start knowing from: its agent's CLI (nil or
    /// unknown for a plain shell) and the conversation the app knows the agent is in.
    struct SessionKnowledge: Equatable {
        let cli: String?
        let conversationID: String?
    }

    /// A session of the project a New Task chat may start knowing from: one running an agent the
    /// app knows a conversation of, in a worktree of its own.
    struct KnowledgeSource: Identifiable, Equatable {
        /// The session's id.
        let id: String
        let title: String
        let cli: String
        let conversationID: String
        let worktree: String
    }

    /// Nil for a standalone chat.
    let projectID: String?
    /// The project's name, or nil for a standalone chat.
    let projectName: String?
    private(set) var folder: String
    /// The session worktree a chat started in a session's pane is tagged with; nil elsewhere.
    let worktreePath: String?
    private(set) var agents: [Agent] = []
    var agent: String? { didSet { if oldValue != agent { Task { await loadModels() } } } }
    private(set) var models: [ChatModelOption] = []
    var model: String?
    private(set) var loading = false
    private(set) var loadingModels = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retired = false
    /// The session whose agent's knowledge the form offers to start with: a pane's own, or the one
    /// picked on New Task; nil otherwise.
    private(set) var knowledgeSession: SessionKnowledge?
    /// Whether this is a pane's form, which offers its own session's knowledge as a switch.
    private let paneKnowledge: Bool
    /// The project's folder, which a New Task chat goes back to when no session's knowledge is picked.
    private let baseFolder: String
    /// New Task's sessions to start knowing from, read as the form loads.
    private(set) var knowledgeSources: [KnowledgeSource] = []
    /// The session picked from them, by id; nil while the chat starts knowing nothing.
    private(set) var knowledgeSourceID: String?
    /// Why the session just picked could not be started from.
    private(set) var knowledgeNote: String?
    @ObservationIgnored var knowledgeSourcesProvider: () -> [KnowledgeSource] = { [] }
    @ObservationIgnored private var knowledgeRequest = UUID()
    /// Start with what the session's agent knows. Off unless the person turns it on.
    var includeKnowledge = false
    /// The first message, in a pane's composer: sent as the chat's first turn once it exists.
    var prompt = ""
    /// The chat made for a Start whose first message then failed: Start again sends it there
    /// rather than making another chat.
    private(set) var startedShell: ChatThreadShell?
    /// The session agent's conversation the backend found, once asked; nil when it has none yet.
    private(set) var knowledgeConversation: String?
    private(set) var knowledgeChecked = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private let service: any ChatServing
    @ObservationIgnored private let chooseFolder: (String) async -> String?
    @ObservationIgnored private var statuses: [String: ChatProviderStatus] = [:]
    @ObservationIgnored private var modelsRequest = UUID()

    /// `agent` is the CLI to offer first, when it is usable: a session's own, in its pane.
    init(projectID: String?, projectName: String?, folder: String, service: any ChatServing,
         chooseFolder: @escaping (String) async -> String? = { _ in nil },
         worktreePath: String? = nil, agent: String? = nil, knowledgeSession: SessionKnowledge? = nil) {
        self.projectID = projectID
        self.knowledgeSession = knowledgeSession
        self.paneKnowledge = knowledgeSession != nil
        self.projectName = projectName
        self.folder = folder
        self.baseFolder = folder
        self.worktreePath = worktreePath
        self.agent = agent
        self.service = service
        self.chooseFolder = chooseFolder
    }

    var standalone: Bool { projectID == nil }

    /// Whether the form offers to start with the session agent's knowledge as a switch: in a pane only.
    var offersKnowledge: Bool { paneKnowledge }
    /// Whether the form offers the project's sessions to start knowing from: New Task's project chat.
    var offersKnowledgeSources: Bool { !standalone && !paneKnowledge && worktreePath == nil }
    var chosenKnowledgeSource: KnowledgeSource? { knowledgeSources.first { $0.id == knowledgeSourceID } }
    /// Why no session can be picked, when none can.
    var knowledgeSourcesReason: String? {
        knowledgeSources.isEmpty ? String(localized: "No session of this project has an agent conversation yet.") : nil
    }
    var canChooseKnowledge: Bool { !retired && !busy && startedShell == nil && !knowledgeSources.isEmpty }

    /// Picks the session whose agent's knowledge the chat starts with, or none. The chat then works
    /// in that session's worktree, where the backend finds the conversation; a session whose agent
    /// has none there is not picked, and says so.
    func chooseKnowledge(_ id: String?) async {
        guard !retired, !busy, offersKnowledgeSources, startedShell == nil else { return }
        let request = UUID()
        knowledgeRequest = request
        knowledgeNote = nil
        let before = folder
        if let id, let source = knowledgeSources.first(where: { $0.id == id }) {
            knowledgeSourceID = id
            knowledgeSession = SessionKnowledge(cli: source.cli, conversationID: source.conversationID)
            knowledgeConversation = nil; knowledgeChecked = false; includeKnowledge = false
            folder = source.worktree
            await checkKnowledge()
            guard !retired, knowledgeRequest == request else { return }
            if knowledgeConversation != nil {
                includeKnowledge = true
            } else {
                clearKnowledge()
                knowledgeNote = String(localized: "\(source.title)’s agent has no conversation to start from.")
            }
        } else {
            clearKnowledge()
        }
        // A CLI may offer a folder models of its own.
        if folder != before { await loadModels() }
    }

    private func clearKnowledge() {
        knowledgeSourceID = nil; knowledgeSession = nil; knowledgeConversation = nil
        knowledgeChecked = false; includeKnowledge = false
        folder = baseFolder
    }

    /// The agent and model, as the composer's agent menu names them.
    var agentTitle: String {
        guard let driver = AgentDrivers.of(agent) else { return String(localized: "Choose an agent") }
        guard let name = models.first(where: { $0.slug == model })?.title else { return driver.shortName }
        return name.localizedCaseInsensitiveContains(driver.shortName) ? name : "\(driver.shortName) \(name)"
    }
    /// The agent's mark on that menu.
    var agentMark: SessionAgent { agent.flatMap(SessionAgent.init(rawValue:)) ?? .shell }
    /// New Task's field, before anything is typed.
    var askPlaceholder: String {
        guard let name = AgentDrivers.of(agent)?.shortName else { return String(localized: "Ask anything") }
        return standalone ? String(localized: "Ask \(name) about this folder") : String(localized: "Ask \(name) about this project")
    }
    /// The session's agent, as the form names it.
    var knowledgeAgentName: String { AgentDrivers.of(knowledgeSession?.cli)?.shortName ?? String(localized: "the session’s agent") }
    var canIncludeKnowledge: Bool { !retired && !busy && knowledgeConversation != nil }
    /// Why the knowledge cannot be included, when it cannot.
    var knowledgeUnavailableReason: String? {
        guard let session = knowledgeSession else { return nil }
        if AgentDrivers.of(session.cli) == nil { return String(localized: "This session runs no agent.") }
        guard knowledgeChecked else { return nil }
        return knowledgeConversation == nil ? String(localized: "The session’s agent has no conversation yet.") : nil
    }

    /// Asks the backend whether the session's agent has a conversation to start from.
    /// Only the conversation the app knows the agent is in counts: without one there is nothing
    /// to ask for, and no other conversation of the worktree stands in for it.
    func checkKnowledge() async {
        guard !retired, let session = knowledgeSession, let driver = AgentDrivers.of(session.cli) else { return }
        guard let conversation = session.conversationID, !conversation.isEmpty else {
            knowledgeConversation = nil; knowledgeChecked = true; includeKnowledge = false
            return
        }
        let found = try? await service.sessionKnowledge(provider: driver.chatProvider, worktree: folder,
                                                        conversationID: conversation)
        // A session picked again while this was asked has its own answer coming.
        guard !retired, knowledgeSession == session else { return }
        knowledgeConversation = found
        knowledgeChecked = true
        if knowledgeConversation == nil { includeKnowledge = false }
    }

    /// What the chat starts knowing, when the person asked for it and there is something to know.
    private var knowledge: ChatKnowledgeSource? {
        guard includeKnowledge, let conversation = knowledgeConversation,
              let driver = AgentDrivers.of(knowledgeSession?.cli) else { return nil }
        return ChatKnowledgeSource(provider: driver.chatProvider, conversationID: conversation)
    }
    var canCreate: Bool {
        !retired && !busy && !folder.isEmpty && agents.contains { $0.cli == agent && $0.usable } && !(model ?? "").isEmpty
    }

    private var typedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A pane's Start: as New Task's, only once something is typed, and the chat starts with it.
    var canStart: Bool { canCreate && !typedPrompt.isEmpty }

    /// A pane's Start: makes the chat and sends the typed text as its first message.
    func start() async {
        guard canStart else { return }
        await create()
    }

    /// The providers, then the chosen agent's models.
    func load() async {
        guard !retired else { return }
        if offersKnowledgeSources { knowledgeSources = knowledgeSourcesProvider() }
        loading = true
        defer { loading = false }
        do {
            let value = try await service.providerStatuses()
            guard !retired else { return }
            let list = (value.array ?? []).compactMap { try? $0.decode(ChatProviderStatus.self) }
            statuses = Dictionary(list.compactMap { status in status.kind.map { ($0, status) } }, uniquingKeysWith: { first, _ in first })
            error = nil
        } catch {
            guard !retired else { return }
            statuses = [:]
            self.error = error.localizedDescription
        }
        agents = AgentDrivers.all.map { driver in
            let status = statuses[driver.chatProvider]
            let usable = status?.usable ?? false
            let note: String? = usable ? nil
                : status == nil ? String(localized: "Not available")
                : status?.message ?? (status?.enabled == false ? String(localized: "Turned off") : String(localized: "Not installed"))
            return Agent(cli: driver.cli, provider: driver.chatProvider, name: driver.shortName, usable: usable, note: note)
        }
        let chosen = agents.first { $0.cli == agent && $0.usable } ?? agents.first(where: \.usable)
        // A change of agent reads its models by itself, but the form waits for them here.
        if chosen?.cli != agent { agent = chosen?.cli }
        await loadModels()
        await checkKnowledge()
    }

    /// The chosen agent's models: the ones its status lists, else what `provider.listModels` says.
    func loadModels() async {
        guard !retired, let agent = agents.first(where: { $0.cli == self.agent }) else { models = []; model = nil; return }
        let request = UUID()
        modelsRequest = request
        loadingModels = true
        defer { if modelsRequest == request { loadingModels = false } }
        var list = statuses[agent.provider]?.models ?? []
        if list.isEmpty {
            do { list = try await service.listModels(provider: agent.provider, cwd: folder) }
            catch {
                guard !retired, modelsRequest == request else { return }
                self.error = error.localizedDescription
            }
        }
        guard !retired, modelsRequest == request else { return }
        models = list
        if !list.contains(where: { $0.slug == model }) { model = (list.first { $0.isDefault == true } ?? list.first)?.slug }
    }

    /// A standalone chat's folder, picked again; the models are read again for it, since a CLI may
    /// offer a folder its own.
    func changeFolder() async {
        guard !retired, standalone, !busy, let picked = await chooseFolder(folder), !retired, picked != folder else { return }
        folder = picked
        await loadModels()
    }

    /// A project chat works in its project's folder: one with none set cannot start a chat.
    var missingFolder: Bool { !standalone && folder.isEmpty }

    /// Makes the chat and, when something is typed, sends it as the first message. The form gives way
    /// to the chat only once both are done; a message that could not be sent stays in the field, and
    /// Start sends it again to the chat already made.
    func create() async {
        guard canCreate, let agent = agents.first(where: { $0.cli == self.agent }), let model else { return }
        busy = true; error = nil
        defer { busy = false }
        let project = projectID ?? ChatProject.standalone
        let title = ChatProject.untitled
        let text = typedPrompt
        do {
            let shell: ChatThreadShell
            if let startedShell {
                shell = startedShell
            } else {
                let id = try await service.createThread(projectID: project, cwd: folder, provider: agent.provider, model: model,
                                                        worktreePath: worktreePath, knowledge: knowledge, title: title)
                let now = ChatTimestamp.string()
                shell = ChatThreadShell(id: id, projectId: project, title: title,
                                        modelSelection: .init(provider: agent.provider, model: model),
                                        runtimeMode: "approval-required", workingDirectory: folder, worktreePath: worktreePath,
                                        createdAt: now, updatedAt: now)
                startedShell = shell
            }
            guard !retired else { return }
            if !text.isEmpty {
                let selection = shell.modelSelection
                try await service.startTurn(threadID: shell.id, text: text, provider: selection?.provider ?? agent.provider,
                                            model: selection?.model ?? model)
                guard !retired else { return }
            }
            onAction(.created(shell))
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
    }

    func retire() {
        retired = true
        onAction = { _ in }
    }
}
