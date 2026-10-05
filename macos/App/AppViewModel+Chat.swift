import AppKit
import Foundation
import OSLog

/// Chat sessions: the list's events, the chat screen's model and what its page asks for, and the
/// sidebar's New Chat, Rename, Archive and Delete.
extension AppViewModel: ChatCoordinating {
    // MARK: Events

    func receiveChat(_ event: ServerEvent) {
        switch event.type {
        case "chat-thread":
            guard let id = event.threadId, let events = event.events, !events.isEmpty,
                  let chat = coordinator.chatCoordinator, chat.threadID == id else { return }
            chat.model.receive(events: events)
        case "chat-shell":
            guard let value = event.shell else { return }
            chats.receive(shell: value)
            guard let id = value["id"]?.string else { return }
            // A chat selected before it was heard of (one the page opened) gets its screen now.
            if selection == .chat(id), coordinator.chatCoordinator?.threadID != id, chats.shell(id) != nil {
                coordinator.refreshRoot()
            }
            updateChatScreen(id)
        case "chat-removed":
            guard let id = event.threadId else { return }
            chats.remove(id)
            coordinator.chatRemoved(id)
        default: break
        }
    }

    /// The list was read: a chat selected before it was (at launch, or from a link) gets its screen,
    /// and one that is gone leaves.
    func chatsLoaded() {
        if case .chat(let id) = selection, chats.loaded, chats.shell(id) == nil {
            select(.overview)
            return
        }
        coordinator.refreshRoot()
        if case .chat(let id) = selection { updateChatScreen(id) }
    }

    private func updateChatScreen(_ id: String) {
        guard let model = coordinator.chatCoordinator?.model, model.threadID == id else { return }
        let shell = chats.shell(id)
        model.update(shell: shell, projectName: chatPlaceName(shell))
    }

    /// Where a chat is, as the page and the toolbar name it: its project, or its folder.
    func chatPlaceName(_ shell: ChatThreadShell?) -> String {
        guard let shell else { return "" }
        if let project = projects.first(where: { $0.id == shell.projectId }) { return project.name }
        let folder = (shell.cwd as NSString).lastPathComponent
        return folder.isEmpty ? String(localized: "Chat") : folder
    }

    // MARK: ChatCoordinating

    func makeChatModel(threadID: String) -> ChatViewModel? {
        guard chatService != nil, let shell = chats.shell(threadID) else { return nil }
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // A subagent's thread follows its parent's agent: the page shows it without a composer.
        let context = ChatPageContext(threadId: threadID, projectId: shell.projectId, cwd: chatFolder(shell),
                                      projectName: chatPlaceName(shell), appearance: dark ? .dark : .light,
                                      readOnly: shell.subagent)
        return chatFactory.chat(threadID: threadID, shell: shell, context: context,
                                backend: ChatServiceBackend(service: { [weak self] in self?.chatService }))
    }

    /// The folder a chat works in: its own, or its project's when it names none.
    func chatFolder(_ shell: ChatThreadShell) -> String {
        shell.cwd.isEmpty ? projects.first { $0.id == shell.projectId }?.workspace ?? "" : shell.cwd
    }

    func performChatAction(_ action: ChatViewModel.Action, threadID: String) {
        // A file the page names is the agent's word: only one inside the chat's folder is followed.
        func confined(_ path: String) -> URL? {
            guard let shell = chats.shell(threadID), let file = ChatFileAccess.confined(path, to: chatFolder(shell)) else { return nil }
            return URL(fileURLWithPath: file)
        }
        switch action {
        case .openLink(let url): desktop.openBrowser(url)
        case .openFile(let path, _):
            guard let url = confined(path) else { return }
            // A chat has no workspace pane of its own: the file opens in its default app, unless
            // opening it would run something (an app, a script Terminal runs), which Finder shows.
            if ChatFileAccess.runsWhenOpened(url.path) { desktop.reveal(url) } else { desktop.openBrowser(url) }
        case .revealFile(let path):
            guard let url = confined(path) else { return }
            desktop.reveal(url)
        case .openFolder(let path):
            guard path.hasPrefix("/") else { return }
            desktop.openBrowser(URL(fileURLWithPath: path, isDirectory: true))
        case .openTurnDiff(_, _, let filePath):
            // The page draws a turn's diff itself. A chat working in a session's worktree can also
            // show that worktree's changes in the session's Diff, scrolled to the file asked for;
            // any other folder has none.
            guard let shell = chats.shell(threadID), let session = sessionWorking(in: chatFolder(shell)) else {
                Logger(subsystem: "com.cascade.app", category: "chat").notice("chat \(threadID, privacy: .public): turn diff asked for, no session's Diff for its folder")
                return
            }
            select(.session(session.id))
            guard let context = viewer.active, context.id == "task:\(session.id)" else { return }
            if context.pane != .diff {
                prepareChanges(for: session, context: context)
                guard diffModels[context.id] != nil else { return }
                context.setPane(.diff)
            }
            if let filePath { diffModels[context.id]?.reveal(path: filePath) }
        case .openThread(let id):
            // The coordinator goes to it; a chat the list has not heard of yet (a fork just made)
            // is read again, and its screen comes when the list has it.
            if chats.shell(id) == nil { chats.reload() }
        case .openSettings:
            coordinator.presentSettingsWindow()
        }
    }

    /// The session whose worktree is `folder`, if any.
    private func sessionWorking(in folder: String) -> WorkspaceSession? {
        guard !folder.isEmpty else { return nil }
        let target = URL(fileURLWithPath: folder).standardizedFileURL.path
        return sessions.first { !$0.worktree.isEmpty && URL(fileURLWithPath: $0.worktree).standardizedFileURL.path == target }
    }

    // MARK: Sidebar and Projects

    func newChat(in projectID: String?) {
        guard let service = chatService else {
            reportRootError(String(localized: "Connect to the backend to start a chat."))
            return
        }
        if let projectID {
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            presentNewChat(projectID: projectID, projectName: project.name, folder: project.workspace, service: service)
            return
        }
        Task { [weak self] in
            // The connection may have changed while the panel was up: the chat goes to the current one.
            guard let self, let folder = await chooseChatFolder(nil), let service = chatService else { return }
            presentNewChat(projectID: nil, projectName: nil, folder: folder, service: service)
        }
    }

    private func presentNewChat(projectID: String?, projectName: String?, folder: String, service: any ChatServing) {
        let choose = chooseChatFolder
        coordinator.presentNewChat({
            chatFactory.newChat(projectID: projectID, projectName: projectName, folder: folder, service: service,
                                chooseFolder: { await choose($0) })
        }, didCreate: { [weak self] shell in
            guard let self else { return }
            chats.receive(shell)
            select(.chat(shell.id))
        })
    }

    func renameChat(_ id: String, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = chatService, !title.isEmpty, chats.shell(id)?.title != title else { return }
        Task { [weak self] in
            do {
                try await service.renameThread(id, to: title)
                guard let self, var shell = chats.shell(id) else { return }
                shell.title = title
                chats.receive(shell)
                updateChatScreen(id)
            } catch { self?.reportRootError(String(localized: "Could not rename the chat: \(error.localizedDescription)")) }
        }
    }

    func archiveChat(_ id: String, archived: Bool) {
        guard let service = chatService, let current = chats.shell(id), current.archived != archived else { return }
        Task { [weak self] in
            do {
                if archived { try await service.archiveThread(id) } else { try await service.unarchiveThread(id) }
                guard let self, var shell = chats.shell(id) else { return }
                shell.archivedAt = archived ? ChatTimestamp.string() : nil
                chats.receive(shell)
                // An archived chat leaves the screen unless archived chats are listed.
                if archived, !showsArchivedChats, selection == .chat(id) { select(.overview) }
            } catch { self?.reportRootError(String(localized: "Could not archive the chat: \(error.localizedDescription)")) }
        }
    }

    /// Asked for once the sidebar's confirmation was answered.
    func deleteChat(_ id: String) {
        guard let service = chatService, chats.shell(id) != nil else { return }
        Task { [weak self] in
            do {
                try await service.deleteThread(id)
                guard let self else { return }
                chats.remove(id)
                coordinator.chatRemoved(id)
            } catch { self?.reportRootError(String(localized: "Could not delete the chat: \(error.localizedDescription)")) }
        }
    }

    func showArchivedChats(_ value: Bool) {
        showsArchivedChats = value
        if !value, case .chat(let id) = selection, chats.shell(id)?.archived == true { select(.overview) }
    }

    /// The system's folder picker, for a standalone chat's working folder.
    static func pickFolder(from start: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder the chat's agent works in.")
        if let start, !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
