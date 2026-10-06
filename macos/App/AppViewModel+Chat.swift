import AppKit
import Foundation
import OSLog

/// Chat sessions: the list's events, the chat screen's model and what its page asks for, New Task's
/// Chat side, and the sidebar's New Chat, Rename, Archive and Delete.
extension AppViewModel: ChatCoordinating {
    // MARK: Events

    func receiveChat(_ event: ServerEvent) {
        switch event.type {
        case "chat-thread":
            guard let id = event.threadId, let events = event.events, !events.isEmpty else { return }
            for context in viewer.contexts.values { context.workspaceViewModel?.receivePaneChatEvents(threadID: id, events: events) }
            guard let chat = coordinator.chatCoordinator, chat.threadID == id else { return }
            chat.model.receive(events: events)
        case "chat-shell":
            guard let value = event.shell else { return }
            chats.receive(shell: value)
            guard let id = value["id"]?.string else { return }
            if let shell = chats.shell(id) {
                for context in viewer.contexts.values {
                    context.workspaceViewModel?.paneChatShellChanged(shell, projectName: chatPlaceName(shell))
                }
            }
            // A chat selected before it was heard of (one the page opened) gets its screen now.
            if selection == .chat(id), coordinator.chatCoordinator?.threadID != id, chats.shell(id) != nil {
                coordinator.refreshRoot()
            }
            updateChatScreen(id)
        case "chat-removed":
            guard let id = event.threadId else { return }
            chats.remove(id)
            coordinator.chatRemoved(id)
            for context in viewer.contexts.values { context.workspaceViewModel?.paneChatRemoved(id) }
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
        return chatModel(for: shell)
    }

    private func chatModel(for shell: ChatThreadShell) -> ChatViewModel {
        let threadID = shell.id
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
        case .unarchive:
            archiveChat(threadID, archived: false)
        }
    }

    // MARK: A session pane's Chat tabs

    var paneChatsConnected: Bool { chatService != nil }
    var paneChatsLoaded: Bool { chats.loaded }
    func paneChatShell(_ id: String) -> ChatThreadShell? { chats.shell(id) }

    func makePaneChat(threadID: String, in context: WorkspaceContext) -> ChatViewModel? {
        guard viewer.contexts[context.id] === context, chatService != nil, let shell = chats.shell(threadID) else { return nil }
        return chatModel(for: shell)
    }

    func makePaneNewChat(in context: WorkspaceContext) -> NewChatViewModel? {
        guard viewer.contexts[context.id] === context, let service = chatService,
              let session = workspaceState(in: context).session, !session.worktree.isEmpty else { return nil }
        let projectName = projects.first { $0.id == session.projectId }?.name ?? ""
        return chatFactory.paneChat(projectID: session.projectId, projectName: projectName, worktree: session.worktree,
                                    agent: session.cli, conversation: session.sessionId, service: service)
    }

    func paneChatStarted(_ shell: ChatThreadShell) { chats.receive(shell) }

    func paneWorktreeChats(_ worktree: String) -> [ChatThreadShell] { chats.inWorktree(worktree) }

    func performPaneChatAction(_ action: ChatViewModel.Action, threadID: String, in context: WorkspaceContext) {
        guard viewer.contexts[context.id] === context else { return }
        // Links, reveals, Settings and the list read again for a chat not heard of yet are the
        // chat screen's; a turn's diff goes to this session's Diff, which is the one its folder names.
        performChatAction(action, threadID: threadID)
    }

    /// The worktrees of the sessions there are, standardized: a chat tagged with one is reached from
    /// its session's pane, and lists leave it out.
    var sessionChatWorktrees: Set<String> {
        Set(sessions.compactMap { $0.worktree.isEmpty ? nil : ChatListStore.standardized($0.worktree) })
    }

    /// The session whose worktree is `folder`, if any.
    private func sessionWorking(in folder: String) -> WorkspaceSession? {
        guard !folder.isEmpty else { return nil }
        let target = URL(fileURLWithPath: folder).standardizedFileURL.path
        return sessions.first { !$0.worktree.isEmpty && URL(fileURLWithPath: $0.worktree).standardizedFileURL.path == target }
    }

    // MARK: Sidebar and Projects

    /// A project's New Chat, from its sidebar row or Projects: New Task, on its Chat side, in that
    /// project. A project with no folder has nowhere for a chat to work, so its Settings open instead.
    func newChat(in projectID: String) {
        guard coordinator.canPresent, let project = projects.first(where: { $0.id == projectID }) else { return }
        guard !project.workspace.isEmpty else {
            openProjectSettings(projectID)
            projectModels[projectID]?.editor.explainMissingFolder()
            return
        }
        select(.newSession)
        coordinator.newSession?.startChat(in: projectID)
    }

    // MARK: New Task's Chat side

    func newSessionChat(in place: NewSessionViewModel.ChatPlace, agent: String?) -> NewChatViewModel? {
        guard let service = chatService else { return nil }
        let choose = chooseChatFolder
        switch place {
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }), !project.workspace.isEmpty else { return nil }
            let model = chatFactory.newChat(projectID: id, projectName: project.name, folder: project.workspace, agent: agent,
                                            service: service, chooseFolder: { await choose($0) })
            model.knowledgeSourcesProvider = { [weak self] in self?.knowledgeSources(in: id) ?? [] }
            return model
        case .folder(let folder):
            return chatFactory.newChat(projectID: nil, projectName: nil, folder: folder, agent: agent,
                                       service: service, chooseFolder: { await choose($0) })
        }
    }

    func newSessionChooseChatFolder(from start: String?) async -> String? { await chooseChatFolder(start) }

    func newSessionChatCreated(_ shell: ChatThreadShell) { chats.receive(shell) }

    /// The project's sessions a chat may start knowing from: those running an agent the app knows
    /// a conversation of, in a worktree of their own.
    func knowledgeSources(in projectID: String) -> [NewChatViewModel.KnowledgeSource] {
        sessions.compactMap { session in
            guard session.projectId == projectID, !session.worktree.isEmpty, let cli = session.cli,
                  AgentDrivers.of(cli) != nil, let conversation = session.sessionId, !conversation.isEmpty else { return nil }
            return .init(id: session.id, title: session.label, cli: cli, conversationID: conversation, worktree: session.worktree)
        }
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
                // Unarchived on its own screen (opened from Archived Chats), its toolbar drops Unarchive.
                updateChatScreen(id)
                // An archived chat is no longer listed: it leaves the screen.
                if archived, selection == .chat(id) { select(.overview) }
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
                for context in viewer.contexts.values { context.workspaceViewModel?.paneChatRemoved(id) }
            } catch { self?.reportRootError(String(localized: "Could not delete the chat: \(error.localizedDescription)")) }
        }
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
