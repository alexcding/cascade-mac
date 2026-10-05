import Foundation
import Observation

/// New Chat: which agent, which of its models, and where it works. A project's chat works in the
/// project's folder; a standalone one in a folder the person picked, which they can change here.
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

    /// Nil for a standalone chat.
    let projectID: String?
    /// The project's name, or nil for a standalone chat.
    let projectName: String?
    private(set) var folder: String
    private(set) var agents: [Agent] = []
    var agent: String? { didSet { if oldValue != agent { Task { await loadModels() } } } }
    private(set) var models: [ChatModelOption] = []
    var model: String?
    private(set) var loading = false
    private(set) var loadingModels = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retired = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    @ObservationIgnored private let service: any ChatServing
    @ObservationIgnored private let chooseFolder: (String) async -> String?
    @ObservationIgnored private var statuses: [String: ChatProviderStatus] = [:]
    @ObservationIgnored private var modelsRequest = UUID()

    init(projectID: String?, projectName: String?, folder: String, service: any ChatServing,
         chooseFolder: @escaping (String) async -> String? = { _ in nil }) {
        self.projectID = projectID
        self.projectName = projectName
        self.folder = folder
        self.service = service
        self.chooseFolder = chooseFolder
    }

    var standalone: Bool { projectID == nil }
    var canCreate: Bool {
        !retired && !busy && !folder.isEmpty && agents.contains { $0.cli == agent && $0.usable } && !(model ?? "").isEmpty
    }

    /// The providers, then the chosen agent's models.
    func load() async {
        guard !retired else { return }
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
        if chosen?.cli != agent { agent = chosen?.cli } else { await loadModels() }
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

    /// A standalone chat's folder, picked again.
    /// A standalone chat's folder, picked again; the models are read again for it, since a CLI may
    /// offer a folder its own.
    func changeFolder() async {
        guard !retired, standalone, !busy, let picked = await chooseFolder(folder), !retired, picked != folder else { return }
        folder = picked
        await loadModels()
    }

    /// A project chat works in its project's folder: one with none set cannot start a chat.
    var missingFolder: Bool { !standalone && folder.isEmpty }

    func create() async {
        guard canCreate, let agent = agents.first(where: { $0.cli == self.agent }), let model else { return }
        busy = true; error = nil
        defer { busy = false }
        let project = projectID ?? ChatProject.standalone
        let title = ChatProject.untitled
        do {
            let id = try await service.createThread(projectID: project, cwd: folder, provider: agent.provider, model: model, title: title)
            guard !retired else { return }
            let now = ChatTimestamp.string()
            onAction(.created(ChatThreadShell(id: id, projectId: project, title: title,
                                              modelSelection: .init(provider: agent.provider, model: model),
                                              runtimeMode: "approval-required", workingDirectory: folder,
                                              createdAt: now, updatedAt: now)))
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
