import Foundation
import Observation

/// New Task, at the top of the sidebar: a project's Start, for whichever project is picked here.
/// It shows that project's own composer rather than one of its own, so a link, a draft or a branch
/// picked on either page is the same one, and a session it makes reaches the app as Start's do.
///
/// Its Chat side starts a chat instead: in the picked project's folder, or with no project in a
/// folder picked for it. The side last chosen is kept across launches.
@MainActor @Observable final class NewSessionViewModel {
    /// What the page asks its coordinator to do.
    enum Action: Equatable {
        case newProject
        /// A chat was started on the Chat side, its first message sent: the window goes to it.
        case chatCreated(ChatThreadShell)
    }
    /// What Start makes: a session, or a chat.
    enum Mode: String, CaseIterable, Identifiable {
        case task, chat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .task: String(localized: "Task")
            case .chat: String(localized: "Chat")
            }
        }
    }
    /// Where the Chat side's chat works: a project's folder, or a folder with no project.
    enum ChatPlace: Equatable {
        case project(String)
        case folder(String)
    }

    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    /// The projects a session can start in: those with a folder.
    private(set) var projects: [Project] = []
    private(set) var projectID: String?
    /// The picked project's Start composer; nil until the backend is there to build it.
    private(set) var composer: ProjectComposerModel?
    private(set) var mode: Mode
    /// The Chat side's form, built while that side is shown; nil until the backend is there.
    private(set) var chat: NewChatViewModel?
    /// The folder a chat with no project works in; nil while the chat is a project's.
    private(set) var chatFolder: String?
    private(set) var retired = false
    /// The project's composer, built when first asked for.
    @ObservationIgnored var composerFor: (String) -> ProjectComposerModel? = { _ in nil }
    /// The Chat side's form for a place, starting on `agent` when it is usable.
    @ObservationIgnored var chatFor: (_ place: ChatPlace, _ agent: String?) -> NewChatViewModel? = { _, _ in nil }
    /// The folder picker, for a chat with no project; nil when cancelled.
    @ObservationIgnored var chooseChatFolder: (_ from: String?) async -> String? = { _ in nil }
    /// The place `chat` was built for.
    @ObservationIgnored private var chatPlace: ChatPlace?

    /// The project picker's New Project.
    func newProject() { if !retired { onAction(.newProject) } }

    private static let projectKey = "newSessionProject"
    static let modeKey = "newSessionMode"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .task
    }

    var project: Project? { projects.first { $0.id == projectID } }

    /// The Chat side's place: the folder picked with no project, else the picked project's.
    var place: ChatPlace? {
        if let chatFolder { return .folder(chatFolder) }
        return projectID.map(ChatPlace.project)
    }

    /// The projects changed, or the backend came: the pick stays when it can, and its composer is
    /// asked for again, as a project's model is rebuilt on reconnect.
    func update(projects: [Project]) {
        guard !retired else { return }
        self.projects = projects.filter { !$0.workspace.isEmpty }
        let saved = UserDefaults.standard.string(forKey: Self.projectKey)
        let next = [projectID, saved].compactMap { $0 }.first { id in self.projects.contains { $0.id == id } }
            ?? self.projects.first?.id
        show(next)
    }

    func choose(_ id: String) {
        guard !retired, projects.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: Self.projectKey)
        chatFolder = nil
        show(id)
    }

    /// The segmented Task | Chat: the person's choice, kept for the next launch.
    func setMode(_ next: Mode) {
        guard !retired else { return }
        UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        switchMode(next)
    }

    /// The project chip's No Project…: a chat in a folder picked now, belonging to no project.
    /// Cancelled, the chat stays where it was.
    func chooseNoProject() async {
        guard !retired, mode == .chat, chat?.busy != true else { return }
        let start = chatFolder ?? project?.workspace
        guard let folder = await chooseChatFolder(start), !retired, !folder.isEmpty else { return }
        chatFolder = folder
        showChat()
    }

    /// Opened to start something: in `projectID` when one is given, with what Start is to hold.
    /// Something to hold is a task's, so it shows the Task side.
    func start(in projectID: String?, text: String? = nil, jiraKey: String? = nil, agent: SessionAgent? = nil) {
        guard !retired else { return }
        if let projectID { choose(projectID) }
        if text != nil || jiraKey != nil || agent != nil { switchMode(.task) }
        composer?.prepare(text: text, jiraKey: jiraKey, agent: agent)
    }

    /// A project's New Chat: the Chat side, in that project.
    func startChat(in projectID: String) {
        guard !retired else { return }
        choose(projectID)
        switchMode(.chat)
    }

    /// The chat backend came or went: the Chat side's form is made again on the current one, keeping
    /// what was typed. A form busy starting its chat is left to finish.
    func chatServiceChanged() {
        guard !retired, chat?.busy != true else { return }
        showChat(again: true)
    }

    func retire() {
        retired = true; composer = nil; onAction = { _ in }; composerFor = { _ in nil }
        chat?.retire(); chat = nil; chatFor = { _, _ in nil }; chooseChatFolder = { _ in nil }
    }

    private func switchMode(_ next: Mode) {
        mode = next
        showChat()
    }

    private func show(_ id: String?) {
        projectID = id
        let next = id.flatMap(composerFor)
        if next !== composer { composer = next }
        showChat()
    }

    /// The Chat side's form, for its place: kept while the place is the same, made anew for another,
    /// with what was typed and the agent picked carried over. Built only while the side is shown.
    private func showChat(again: Bool = false) {
        guard !retired, mode == .chat else { return }
        let place = place
        if !again, let chat, !chat.retired, place == chatPlace { return }
        let previous = chat
        guard let place, let next = chatFor(place, previous?.agent) else {
            previous?.retire(); chat = nil; chatPlace = nil
            return
        }
        if let previous { next.prompt = previous.prompt; previous.retire() }
        next.onAction = { [weak self, weak next] action in
            guard let self, let next, !retired, chat === next else { return }
            switch action {
            case .created(let shell):
                // The chat is made and its first message sent: a fresh form for the next one.
                next.retire(); chat = nil; chatPlace = nil
                showChat()
                onAction(.chatCreated(shell))
            }
        }
        chat = next
        chatPlace = place
    }
}
