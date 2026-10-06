import Foundation
import Observation

@MainActor protocol NewSessionFeatureFactory {
    func newSession() -> NewSessionViewModel
}

@MainActor struct NativeNewSessionFeatureFactory: NewSessionFeatureFactory {
    func newSession() -> NewSessionViewModel { NewSessionViewModel() }
}

/// What New Task needs from the app: a project's Start composer, and New Project; on its Chat side,
/// a chat's form, the folder picker for a chat with no project, and the chat it started.
@MainActor protocol NewSessionCoordinating: AnyObject {
    func newSessionComposer(for projectID: String) -> ProjectComposerModel?
    func newSessionNewProject()
    /// The Chat side's form for `place`, on `agent` when usable; nil while not connected.
    func newSessionChat(in place: NewSessionViewModel.ChatPlace, agent: String?) -> NewChatViewModel?
    func newSessionChooseChatFolder(from start: String?) async -> String?
    /// A chat New Task started: the list hears of it before the window goes to it.
    func newSessionChatCreated(_ shell: ChatThreadShell)
}

/// New Task's coordinator. The page shows a project's own Start composer, which the project's
/// model owns, so this holds only the page's model and gates what it asks for.
@MainActor @Observable final class NewSessionCoordinator {
    let model: NewSessionViewModel
    private(set) var retired = false
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    /// Takes the window to a chat.
    @ObservationIgnored var showChat: (String) -> Void = { _ in }
    @ObservationIgnored private weak var runtime: (any NewSessionCoordinating)?

    init(model: NewSessionViewModel, runtime: (any NewSessionCoordinating)?) {
        self.model = model
        self.runtime = runtime
        model.onAction = { [weak self] in self?.handle($0) }
        model.composerFor = { [weak self] id in
            guard let self, !retired, isOwned() else { return nil }
            return self.runtime?.newSessionComposer(for: id)
        }
        model.chatFor = { [weak self] place, agent in
            guard let self, !retired, isOwned() else { return nil }
            return self.runtime?.newSessionChat(in: place, agent: agent)
        }
        model.chooseChatFolder = { [weak self] start in
            guard let self, !retired, isOwned(), canPresent() else { return nil }
            return await self.runtime?.newSessionChooseChatFolder(from: start)
        }
    }

    func handle(_ action: NewSessionViewModel.Action) {
        guard !retired, isOwned(), canPresent() else { return }
        switch action {
        case .newProject: runtime?.newSessionNewProject()
        case .chatCreated(let shell):
            runtime?.newSessionChatCreated(shell)
            showChat(shell.id)
        }
    }

    func retire() { retired = true; isOwned = { false }; canPresent = { false }; showChat = { _ in }; model.retire() }
}

extension AppCoordinator {
    @discardableResult func installNewSession(_ model: NewSessionViewModel, runtime: (any NewSessionCoordinating)?) -> NewSessionCoordinator {
        if let existing = newSessionCoordinator, existing.model === model { return existing }
        newSessionCoordinator?.retire()
        let child = NewSessionCoordinator(model: model, runtime: runtime)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return newSessionCoordinator?.model === model
        }
        child.canPresent = { [weak self] in self?.selection == .newSession && self?.canPresent == true }
        child.showChat = { [weak self] id in self?.navigate(to: .chat(id)) }
        newSessionCoordinator = child
        return child
    }

    func makeNewSession(factory: any NewSessionFeatureFactory, runtime: (any NewSessionCoordinating)?) -> NewSessionViewModel {
        installNewSession(factory.newSession(), runtime: runtime).model
    }
}
