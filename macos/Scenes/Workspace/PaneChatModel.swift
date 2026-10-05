import Foundation
import Observation

/// One Chat tab of a session's pane: a headless chat of its own (its own thread in the chat
/// backend) working in the session's worktree, beside the terminal's agent but not tied to its
/// conversation. Until a chat is started in it the tab shows the new-chat form; then the chat's
/// page. Owned by the session's workspace model, which retires it with its tab or its session.
/// Retired is terminal: a retired tab shows nothing again.
@MainActor @Observable final class PaneChatModel {
    let tab: WorkspaceToolTab
    /// The new-chat form, while no chat is started in the tab.
    private(set) var form: NewChatViewModel?
    /// The chat the tab shows; its page owns the web view.
    private(set) var chat: ChatViewModel?
    private(set) var retired = false

    init(tab: WorkspaceToolTab) { self.tab = tab }

    var threadID: String? { chat?.threadID }

    func show(form: NewChatViewModel) {
        guard !retired else { form.retire(); return }
        self.form?.retire()
        self.form = form
    }

    /// The chat replaces the form, or the chat shown before it.
    func show(chat: ChatViewModel) {
        guard !retired else { chat.retire(); return }
        form?.retire(); form = nil
        if let old = self.chat, old !== chat { old.retire() }
        self.chat = chat
    }

    func retire() {
        guard !retired else { return }
        retired = true
        form?.retire(); form = nil
        chat?.retire(); chat = nil
    }
}
