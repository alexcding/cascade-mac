import Foundation
import Observation

/// New Task, at the top of the sidebar: a project's Start, for whichever project is picked here.
/// It shows that project's own composer rather than one of its own, so a link, a draft or a branch
/// picked on either page is the same one, and a session it makes reaches the app as Start's do.
///
/// Its Chat side starts a chat instead, in the project its project chip picks, working in the
/// project's folder, or in none, working in a scratch folder of its own. A chat has no branch: it
/// works in the folder as it is. The side last chosen is kept across launches; the chat's project
/// (`chatProjectID`) is the page's alone, kept while the app runs and none at launch.
@MainActor @Observable final class NewSessionViewModel {
    /// What the page asks its coordinator to do.
    enum Action: Equatable {
        /// `forChat` from the Chat side's chip: the chat starts in the project made.
        case newProject(forChat: Bool)
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
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    /// The projects a session can start in: those with a folder.
    private(set) var projects: [Project] = []
    private(set) var projectID: String?
    /// The picked project's Start composer; nil until the backend is there to build it.
    private(set) var composer: ProjectComposerModel?
    private(set) var mode: Mode
    /// The project the Chat side's chat works in; nil for none, a scratch folder of the chat's own, as
    /// at launch. Every form is placed from it (`placeChat`): the form never decides for itself.
    private(set) var chatProjectID: String?
    /// The Chat side's form, built while that side is shown; nil until the backend is there.
    private(set) var chat: NewChatViewModel?
    private(set) var retired = false
    /// The project's composer, built when first asked for.
    @ObservationIgnored var composerFor: (String) -> ProjectComposerModel? = { _ in nil }
    /// The Chat side's form, starting on `agent` when it is usable.
    @ObservationIgnored var chatFor: (_ agent: String?) -> NewChatViewModel? = { _ in nil }

    /// The Task side's New Project.
    func newProject() { if !retired { onAction(.newProject(forChat: false)) } }
    /// The Chat side's New Project: the chat starts in it once it is made.
    func newChatProject() { if !retired { onAction(.newProject(forChat: true)) } }

    private static let projectKey = "newSessionProject"
    static let modeKey = "newSessionMode"

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .task
    }

    var project: Project? { projects.first { $0.id == projectID } }
    /// The Chat side's project, while it is one a chat can start in.
    var chatProject: Project? { projects.first { $0.id == chatProjectID } }

    /// The projects changed, or the backend came: the pick stays when it can, and its composer is
    /// asked for again, as a project's model is rebuilt on reconnect.
    func update(projects: [Project]) {
        guard !retired else { return }
        self.projects = projects.filter { !$0.workspace.isEmpty }
        let saved = UserDefaults.standard.string(forKey: Self.projectKey)
        let next = [projectID, saved].compactMap { $0 }.first { id in self.projects.contains { $0.id == id } }
            ?? self.projects.first?.id
        show(next)
        // A project gone, renamed or its folder moved: the form there follows, and one made now starts there.
        placeChat()
        showChat()
    }

    func choose(_ id: String) {
        guard !retired, projects.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: Self.projectKey)
        show(id)
    }

    /// The Chat side's project chip: a project, working in its folder, or none (nil), working in a
    /// scratch folder of its own. Kept while the app runs, for the next chat; taken with no form
    /// there (not connected) for the one made when it is. Not while a chat is being started.
    func chooseChatProject(_ id: String?) {
        guard !retired, chat?.canMove != false, id == nil || projects.contains(where: { $0.id == id }) else { return }
        chatProjectID = id
        placeChat()
    }

    /// The form placed in `chatProjectID`. A project no longer listed is no longer the pick: the chat
    /// goes back to none, and does not return to it by itself if it comes back.
    private func placeChat() {
        if chatProjectID != nil, chatProject == nil { chatProjectID = nil }
        chat?.place(in: chatProject)
    }

    /// The segmented Task | Chat: the person's choice, kept for the next launch.
    func setMode(_ next: Mode) {
        guard !retired else { return }
        UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        switchMode(next)
    }

    /// Opened to start something: in `projectID` when one is given, with what Start is to hold.
    /// Something to hold is a task's, so it shows the Task side.
    func start(in projectID: String?, text: String? = nil, jiraKey: String? = nil, agent: SessionAgent? = nil) {
        guard !retired else { return }
        // The Task side's project only: the chat stays where the person put it.
        if let projectID { choose(projectID) }
        if text != nil || jiraKey != nil || agent != nil { switchMode(.task) }
        composer?.prepare(text: text, jiraKey: jiraKey, agent: agent)
    }

    /// The chat backend came or went: the Chat side's form is made again on the current one, keeping
    /// what was typed. A form busy starting its chat is left to finish.
    func chatServiceChanged() {
        guard !retired, chat?.busy != true else { return }
        showChat(again: true)
    }

    func retire() {
        retired = true; composer = nil; onAction = { _ in }; composerFor = { _ in nil }
        chat?.retire(); chat = nil; chatFor = { _ in nil }
    }

    private func switchMode(_ next: Mode) {
        mode = next
        showChat()
    }

    private func show(_ id: String?) {
        projectID = id
        let next = id.flatMap(composerFor)
        if next !== composer { composer = next }
    }

    /// The Chat side's form: kept while it is there, made anew on reconnect with what was typed and
    /// the agent carried over. Built only while the side is shown.
    private func showChat(again: Bool = false) {
        guard !retired, mode == .chat else { return }
        if !again, let chat, !chat.retired { return }
        let previous = chat
        guard let next = chatFor(previous?.agent) else {
            previous?.retire(); chat = nil
            return
        }
        chat = next
        // Where the page says; a chat started already keeps where it was made (`carryDraft`).
        placeChat()
        if let previous {
            next.carryDraft(from: previous)
            previous.retire()
        }
        next.onAction = { [weak self, weak next] action in
            guard let self, let next, !retired, chat === next else { return }
            switch action {
            case .created(let shell):
                // The chat is made and its first message sent: a fresh form for the next one.
                next.retire(); chat = nil
                showChat()
                onAction(.chatCreated(shell))
            }
        }
    }
}
