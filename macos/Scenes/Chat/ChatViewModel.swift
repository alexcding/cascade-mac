import Foundation
import Observation

/// A chat session's screen: the chat page for one thread, with what the toolbar shows of it (its
/// title, its agent, its folder). The thread runs in the backend; this model only shows it, and
/// reports what the page asks of the app through `Action`.
@MainActor @Observable final class ChatViewModel {
    enum Action: Equatable {
        case openLink(URL)
        case openFile(path: String, line: Int?)
        case revealFile(String)
        /// "Review" on a turn's changed files.
        case openTurnDiff(threadID: String, turnID: String, filePath: String?)
        /// Synara's "Manage providers".
        case openSettings
        /// Another chat, which the page made (a fork, a review): shown in place of this one.
        case openThread(String)
        /// The toolbar's Unarchive, on an archived chat opened from a sidebar menu's Archived Chats.
        case unarchive
    }

    let threadID: String
    let page: ChatPageModel
    private(set) var shell: ChatThreadShell?
    private(set) var projectName: String
    private(set) var retired = false
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }

    init(threadID: String, shell: ChatThreadShell?, projectName: String, page: ChatPageModel) {
        self.threadID = threadID
        self.shell = shell
        self.projectName = projectName
        self.page = page
        page.onEvent = { [weak self] event in self?.pageEvent(event) }
    }

    var title: String { shell?.label ?? String(localized: "Chat") }
    var cwd: String {
        if let folder = shell?.cwd, !folder.isEmpty { return folder }
        return page.context.cwd
    }
    /// The CLI answering it, for its glyph.
    var cli: String? { shell?.cli }
    var model: String? { shell?.modelSelection?.model }

    /// The backend's latest word on this chat (`chat-shell`), or the project it is in, renamed.
    func update(shell: ChatThreadShell?, projectName: String) {
        guard !retired else { return }
        if let shell, shell.id == threadID, self.shell != shell { self.shell = shell }
        if self.projectName != projectName { self.projectName = projectName }
        page.update(projectName: projectName, cwd: shell?.cwd)
    }

    /// The thread's events from a `chat-thread` event.
    func receive(events: [JSONValue]) {
        guard !retired else { return }
        page.receiveThreadEvents(events)
    }

    /// Archived: listed nowhere, reached from Archived Chats; its toolbar offers Unarchive.
    var archived: Bool { shell?.archived ?? false }

    func unarchive() {
        guard !retired, archived else { return }
        onAction(.unarchive)
    }

    private func pageEvent(_ event: ChatPageEvent) {
        guard !retired else { return }
        switch event {
        case .openLink(let url): onAction(.openLink(url))
        case .openFile(let path, let line): onAction(.openFile(path: path, line: line))
        case .revealFile(let path): onAction(.revealFile(path))
        case .openTurnDiff(let thread, let turn, let file): onAction(.openTurnDiff(threadID: thread, turnID: turn, filePath: file))
        case .openSettings: onAction(.openSettings)
        case .openThread(let id): onAction(.openThread(id))
        }
    }

    func retire() {
        guard !retired else { return }
        retired = true
        onAction = { _ in }
        page.retire()
    }
}
