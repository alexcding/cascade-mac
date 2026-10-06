import Foundation
import Observation

/// Builds a chat screen's model, so tests can stand in a page that makes no web view.
@MainActor protocol ChatFeatureFactory {
    func chat(threadID: String, shell: ChatThreadShell?, context: ChatPageContext, backend: any ChatPageBackend) -> ChatViewModel
    /// New Task's Chat side: a chat of no project, in a scratch folder the backend makes unless
    /// `chooseFolder` picks one, on `agent` when it is usable.
    func newChat(agent: String?, service: any ChatServing, chooseFolder: @escaping (String) async -> String?) -> NewChatViewModel
    /// The new-chat form of a Chat tab in a session's pane: the chat works in the session's
    /// worktree and is tagged with it, on the session's agent unless another is picked, and may
    /// start with what that agent knows in `conversation`.
    func paneChat(projectID: String, projectName: String, worktree: String, agent: String?, conversation: String?,
                  service: any ChatServing) -> NewChatViewModel
}

extension ChatFeatureFactory {
    func paneChat(projectID: String, projectName: String, worktree: String, agent: String?, conversation: String?,
                  service: any ChatServing) -> NewChatViewModel {
        NewChatViewModel(projectID: projectID, projectName: projectName, folder: worktree, service: service,
                         worktreePath: worktree, agent: agent,
                         knowledgeSession: .init(cli: agent, conversationID: conversation))
    }
}

@MainActor struct NativeChatFeatureFactory: ChatFeatureFactory {
    func chat(threadID: String, shell: ChatThreadShell?, context: ChatPageContext, backend: any ChatPageBackend) -> ChatViewModel {
        ChatViewModel(threadID: threadID, shell: shell, projectName: context.projectName,
                      page: ChatPageModel(context: context, backend: backend))
    }
    func newChat(agent: String?, service: any ChatServing, chooseFolder: @escaping (String) async -> String? = { _ in nil }) -> NewChatViewModel {
        NewChatViewModel(projectID: nil, projectName: nil, folder: "", service: service, chooseFolder: chooseFolder, agent: agent)
    }
}

/// What the app does for a chat screen: make its model when a chat is selected, and act on what
/// its page asks for. `AppViewModel` is the one runtime.
@MainActor protocol ChatCoordinating: AnyObject {
    /// The model for the chat `threadID`, or nil while the app cannot show it (not connected).
    func makeChatModel(threadID: String) -> ChatViewModel?
    func performChatAction(_ action: ChatViewModel.Action, threadID: String)
}

/// One chat on screen. A chat's coordinator lives while its chat is selected, and retires when the
/// selection moves on or the chat is deleted; its model and page go with it.
@MainActor @Observable final class ChatCoordinator: Coordinatable {
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: ChatViewModel
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    /// What the page asked for, handed to the app.
    @ObservationIgnored var perform: (ChatViewModel.Action) -> Void = { _ in }

    init(model: ChatViewModel) {
        self.model = model
        root = .chat(model)
        model.onAction = { [weak self] in self?.handle($0) }
    }

    var threadID: String { model.threadID }

    func makeDestination(for route: Route) -> Destination { .none }
    func handle(_ action: Action) { self.action?(action) }
    func handle(_ action: ChatViewModel.Action) {
        guard !retired, isOwned() else { return }
        perform(action)
    }
    func retire() {
        guard !retired else { return }
        retired = true; isOwned = { false }; canPresent = { false }; perform = { _ in }
        model.retire()
    }
}

extension AppCoordinator {
    /// Shows `model` as the chat on screen, retiring the one before it.
    @discardableResult func installChat(_ model: ChatViewModel) -> ChatCoordinator {
        if let existing = chatCoordinator, existing.model === model { return existing }
        chatCoordinator?.retire()
        let child = ChatCoordinator(model: model)
        let id = model.threadID
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return chatCoordinator?.model === model
        }
        child.canPresent = { [weak self] in
            self?.selection == .chat(id) && self?.canPresent == true && self?.canOpenExternalRoute() == true
        }
        child.perform = { [weak self] action in
            guard let self else { return }
            // The app hears of it first, so it can read the list again for a chat it has not heard
            // of yet; the window then goes to that chat, which retires this one.
            chatRuntime?.performChatAction(action, threadID: id)
            if case .openThread(let other) = action, other != id { navigate(to: .chat(other)) }
        }
        chatCoordinator = child
        return child
    }

    /// The chat coordinator follows the selection: made for the chat selected, retired when the
    /// selection is not a chat or is another one. Called before `root` is rebuilt.
    func syncChatCoordinator() {
        guard case .chat(let id) = selection else {
            if let current = chatCoordinator { chatCoordinator = nil; current.retire() }
            return
        }
        if chatCoordinator?.threadID == id, chatCoordinator?.retired == false { return }
        if let current = chatCoordinator { chatCoordinator = nil; current.retire() }
        if let model = chatRuntime?.makeChatModel(threadID: id) { installChat(model) }
    }

    /// A chat was deleted: its screen goes, and the window goes back to Projects if it showed it.
    func chatRemoved(_ id: String) {
        guard chatCoordinator?.threadID == id || selection == .chat(id) else { return }
        if selection == .chat(id) { navigate(to: .overview) } else { syncChatCoordinator(); refreshRoot() }
    }
}
