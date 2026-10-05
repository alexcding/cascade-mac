import Foundation
import Observation
import Testing
@testable import Cascade

// A session pane's Chat tabs: each a headless chat of its own, working in the session's worktree.

/// A chat service whose every call is answered by a closure; the commands dispatched are kept.
private final class RecordingChat: ChatServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [JSONValue] = []
    private var _knowledgeAsks: [JSONValue] = []
    var commands: [JSONValue] { lock.withLock { _commands } }
    var knowledgeAsks: [JSONValue] { lock.withLock { _knowledgeAsks } }
    /// What `chat.sessionKnowledge` finds: the session agent's conversation, or none.
    var conversation: String?

    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.providerStatuses":
            return [["provider": "claudeAgent", "available": true, "models": [["slug": "opus", "isDefault": true]]],
                    ["provider": "codex", "available": true, "models": [["slug": "gpt-5", "isDefault": true]]]]
        case "orchestration.dispatchCommand":
            lock.withLock { _commands.append(params["command"] ?? .null) }
            return ["sequence": 1]
        case "chat.sessionKnowledge":
            lock.withLock { _knowledgeAsks.append(params) }
            return conversation.map { ["conversationId": .string($0)] } ?? .null
        default: return .null
        }
    }
}

private struct QuietPageBackend: ChatPageBackend {
    func call(_ method: String, params: JSONValue) async throws -> JSONValue { .null }
    func providers() async throws -> JSONValue { [] }
    func snapshot(threadID: String) async throws -> JSONValue { .null }
}

/// The app as a session's pane sees it: a session, the chats the list has, and pages made with no
/// web view.
@MainActor @Observable private final class PaneChatFixture: WorkspaceServing {
    var state = SessionWorkspaceState()
    var shells: [String: ChatThreadShell] = [:]
    var started: [ChatThreadShell] = []
    var forwarded: [ChatViewModel.Action] = []
    @ObservationIgnored let chat = RecordingChat()
    @ObservationIgnored var pages: [ChatPageModel] = []

    func workspaceState(in context: WorkspaceContext) -> SessionWorkspaceState { state }
    var paneChatsConnected: Bool { true }
    var paneChatsLoaded: Bool { true }
    func paneChatShell(_ id: String) -> ChatThreadShell? { shells[id] }
    func makePaneChat(threadID: String, in context: WorkspaceContext) -> ChatViewModel? {
        guard let shell = shells[threadID] else { return nil }
        let page = ChatPageModel(context: ChatPageContext(threadId: threadID, projectId: shell.projectId, cwd: shell.cwd, projectName: "P"),
                                 backend: QuietPageBackend(), output: { _ in })
        pages.append(page)
        return ChatViewModel(threadID: threadID, shell: shell, projectName: "P", page: page)
    }
    func makePaneNewChat(in context: WorkspaceContext) -> NewChatViewModel? {
        guard let session = state.session else { return nil }
        return NativeChatFeatureFactory().paneChat(projectID: session.projectId, projectName: "P", worktree: session.worktree,
                                                   agent: session.cli, conversation: session.sessionId, service: chat)
    }
    func paneChatStarted(_ shell: ChatThreadShell) { started.append(shell); shells[shell.id] = shell }
    func paneWorktreeChats(_ worktree: String) -> [ChatThreadShell] {
        let store = ChatListStore()
        shells.values.forEach(store.receive)
        return store.inWorktree(worktree)
    }
    func performPaneChatAction(_ action: ChatViewModel.Action, threadID: String, in context: WorkspaceContext) { forwarded.append(action) }
}

@MainActor private func session(cli: String = "codex", conversation: String? = nil) -> WorkspaceSession {
    WorkspaceSession(id: "s1", projectId: "proj", workspace: "/repo", worktree: "/repo-wt/s1", title: "S1",
                     branch: "s1", url: "", createdAt: nil, pinned: false, cli: cli, sessionId: conversation)
}

@MainActor private func shell(_ id: String, worktree: String? = "/repo-wt/s1", parent: String? = nil) -> ChatThreadShell {
    ChatThreadShell(id: id, projectId: "proj", title: "Chat \(id)", modelSelection: .init(provider: "codex", model: "gpt-5"),
                    workingDirectory: worktree, worktreePath: worktree, createdAt: "2026-10-0\(id.count)T00:00:00.000Z",
                    parentThreadId: parent)
}

@MainActor struct PaneChatTests {
    @Test func chatTabsAreManyAndKeepTheirChatsAcrossARelaunch() throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let page = try #require(context.open("https://example.com/home", title: "Home"))
        let first = context.openChat()
        #expect(first == .chat && context.activeTool == .chat && context.pane == .term)
        #expect(context.chatThread(for: first) == nil, "a new tab shows the form until a chat is started")
        context.bindChat(first, thread: "t1")
        let second = context.openChat(thread: "t2")
        #expect(second == WorkspaceToolTab(.chat, number: 2), "another tab, not the first again")
        #expect(context.openChat(thread: "t1") == first && context.activeID == first.id, "a chat already in a tab is selected")

        let encoded = try JSONEncoder().encode(context.snapshot)
        let restored = WorkspaceContext(id: context.id, sourceURL: "session:s1", title: "",
                                        snapshot: try JSONDecoder().decode(ContextSnapshot.self, from: encoded))
        #expect(restored.tabs.map(\.id) == context.tabs.map(\.id) && restored.tabs.first?.id == page.id)
        #expect(restored.chatThread(for: first) == "t1" && restored.chatThread(for: second) == "t2")
        #expect(restored.activeID == first.id)

        restored.close(.tool(second))
        #expect(restored.chatThread(for: second) == nil && !restored.tools.contains(second))
        #expect(restored.snapshot.chats == ["chat": "t1"], "closing a tab forgets its binding, not the other's")
        let reopened = restored.openChat()
        #expect(reopened == second && restored.chatThread(for: reopened) == nil, "a reused number starts afresh")
    }

    @Test func theFormStartsAChatInTheWorktreeTaggedWithIt() async throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session(cli: "codex")
        #expect(model.startPageTools().contains { $0.id == "chat" })
        let tab = context.openChat()
        model.preparePaneChat(tab)
        let form = try #require(model.paneChat(for: tab)?.form)
        #expect(form.agent == "codex", "the session's own agent is offered first")
        #expect(form.folder == "/repo-wt/s1" && form.worktreePath == "/repo-wt/s1")
        await form.load()
        #expect(form.agent == "codex" && form.model == "gpt-5")
        await form.create()

        let command = try #require(service.chat.commands.first)
        #expect(command["type"]?.string == "thread.create")
        #expect(command["projectId"]?.string == "proj")
        #expect(command["workingDirectory"]?.string == "/repo-wt/s1")
        #expect(command["worktreePath"]?.string == "/repo-wt/s1")
        #expect(command["modelSelection"]?["provider"]?.string == "codex")
        let thread = try #require(command["threadId"]?.string)
        #expect(service.started.map(\.id) == [thread] && service.started.first?.worktreePath == "/repo-wt/s1")
        #expect(context.chatThread(for: tab) == thread, "the tab shows the chat it started")
        #expect(form.retired && model.paneChat(for: tab)?.chat?.threadID == thread, "the form gave way to the chat")
        #expect(model.paneChatTitle(tab) == "New Chat", "titled from its first message by the backend")
    }

    @Test func theKnowledgeCheckboxIsOffAndOnlyWhatItSaysIsSent() async throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session(cli: "claude", conversation: "conv-1")
        service.chat.conversation = "conv-1"
        let first = context.openChat()
        model.preparePaneChat(first)
        let form = try #require(model.paneChat(for: first)?.form)
        #expect(form.offersKnowledge && !form.includeKnowledge, "offered in a pane, off by default")
        await form.load()
        let ask = try #require(service.chat.knowledgeAsks.first)
        #expect(ask["provider"]?.string == "claudeAgent" && ask["worktree"]?.string == "/repo-wt/s1")
        #expect(ask["conversationId"]?.string == "conv-1")
        #expect(form.canIncludeKnowledge && form.knowledgeUnavailableReason == nil && !form.includeKnowledge)
        await form.create()
        let plain = try #require(service.chat.commands.last)
        #expect(plain["knowledgeSource"] == nil, "left off, the chat starts knowing nothing")

        let second = context.openChat()
        model.preparePaneChat(second)
        let knowing = try #require(model.paneChat(for: second)?.form)
        await knowing.load()
        knowing.agent = "codex"
        await knowing.loadModels()
        knowing.includeKnowledge = true
        await knowing.create()
        let command = try #require(service.chat.commands.last)
        #expect(command["modelSelection"]?["provider"]?.string == "codex")
        #expect(command["knowledgeSource"] == ["provider": "claudeAgent", "conversationId": "conv-1"],
                "the session's agent and conversation, whatever agent the chat runs")
    }

    @Test func theKnowledgeCheckboxIsDisabledWithoutAConversation() async throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session(cli: "claude", conversation: "not-yet")
        let tab = context.openChat()
        model.preparePaneChat(tab)
        let form = try #require(model.paneChat(for: tab)?.form)
        await form.load()
        #expect(!form.canIncludeKnowledge && form.knowledgeUnavailableReason == "The session’s agent has no conversation yet.")
        form.includeKnowledge = true
        await form.create()
        #expect(service.chat.commands.last?["knowledgeSource"] == nil, "nothing to start from, nothing sent")

        service.state.session = session(cli: "")
        let shellTab = context.openChat()
        model.preparePaneChat(shellTab)
        let shellForm = try #require(model.paneChat(for: shellTab)?.form)
        #expect(shellForm.knowledgeUnavailableReason == "This session runs no agent." && !shellForm.canIncludeKnowledge)
        #expect(NewChatViewModel(projectID: nil, projectName: nil, folder: "/x", service: service.chat).offersKnowledge == false,
                "only a pane's form offers it")
    }

    @Test func theKnowledgeIsNotAskedForWithoutTheAgentsConversation() async throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session(cli: "claude", conversation: nil)
        service.chat.conversation = "the-worktrees-newest"
        let tab = context.openChat()
        model.preparePaneChat(tab)
        let form = try #require(model.paneChat(for: tab)?.form)
        await form.load()
        #expect(service.chat.knowledgeAsks.isEmpty, "no other conversation stands in for the agent's")
        #expect(!form.canIncludeKnowledge && form.knowledgeUnavailableReason == "The session’s agent has no conversation yet.")
    }

    @Test func theFormOffersTheWorktreesChatsNoTabShows() throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session()
        var archived = shell("dddd"); archived.archivedAt = "2026-10-05T00:00:00.000Z"
        var working = shell("bb"); working.session = .init(status: "running")
        var asking = shell("a"); asking.hasPendingApprovals = true
        service.shells = ["a": asking, "bb": working, "ccc": shell("ccc", worktree: "/elsewhere"), "dddd": archived,
                          "eeeee": shell("eeeee", parent: "a"), "ffffff": shell("ffffff")]
        let shown = context.openChat(thread: "ffffff")
        let tab = context.openChat()
        model.preparePaneChat(tab)
        #expect(model.paneChat(for: tab)?.form != nil)
        // Newest first; another worktree's, an archived one, a subagent's and the one a tab shows left out.
        #expect(model.paneExistingChats(tab).map(\.id) == ["bb", "a"])
        #expect(model.paneExistingChats(tab).first?.working == true && model.paneExistingChats(tab).last?.needsInput == true)
        context.close(.tool(shown))
        #expect(model.paneExistingChats(tab).map(\.id) == ["ffffff", "bb", "a"], "a closed tab's chat is offered again")

        model.openExistingPaneChat("ccc", in: tab)
        #expect(context.chatThread(for: tab) == nil, "only the worktree's own chats")
        model.openExistingPaneChat("a", in: tab)
        #expect(context.chatThread(for: tab) == "a")
        #expect(model.paneChat(for: tab)?.form == nil && model.paneChat(for: tab)?.chat?.threadID == "a", "opened in this tab")
        #expect(model.paneExistingChats(tab).map(\.id) == [], "a tab that shows a chat offers none")
    }

    @Test func listsLeaveOutTheChatsOfASessionsPane() {
        let store = ChatListStore()
        store.receive(shell("a"))
        store.receive(shell("bb", worktree: nil))
        store.receive(shell("ccc", worktree: "/elsewhere"))
        let worktrees: Set<String> = [ChatListStore.standardized("/repo-wt/s1/")]
        #expect(Set(store.visible().map(\.id)) == ["a", "bb", "ccc"])
        #expect(Set(store.visible(excludingWorktrees: worktrees).map(\.id)) == ["bb", "ccc"], "reached from its session")
        #expect(store.grouped(projectIDs: ["proj"], excludingWorktrees: worktrees).byProject["proj"]?.map(\.id).sorted() == ["bb", "ccc"])
        #expect(Set(store.visible(excludingWorktrees: []).map(\.id)).contains("a"), "its session gone, it is listed again")
    }

    @Test func anotherChatThePageOpensGetsATabOfItsOwn() throws {
        let context = WorkspaceContext(id: "task:s1", sourceURL: "session:s1", title: "")
        let service = PaneChatFixture(), model = SessionWorkspaceViewModel(context: context, service: service)
        service.state.session = session()
        service.shells = ["t1": shell("t1"), "fork": shell("fork")]
        let tab = context.openChat(thread: "t1")
        model.preparePaneChat(tab)
        let chat = try #require(model.paneChat(for: tab)?.chat)
        #expect(model.paneChatTitle(tab) == "Chat t1" && model.paneChatCLI(tab) == "codex")
        chat.onAction(.openThread("fork"))
        let forkTab = try #require(context.activeID.flatMap(WorkspaceToolTab.init(id:)))
        #expect(forkTab != tab && forkTab.tool == .chat && context.chatThread(for: forkTab) == "fork")
        #expect(service.forwarded == [.openThread("fork")], "the app hears of it, to read the list for one it has not")
        #expect(context.chatThread(for: tab) == "t1", "the chat it came from keeps its tab")
        chat.onAction(.openLink(URL(string: "https://example.com")!))
        #expect(service.forwarded.last == .openLink(URL(string: "https://example.com")!))
    }

    @Test func aChatTabsPageGoesWithItsTabAndItsSession() async throws {
        let viewer = ViewerStore()
        let context = viewer.restore(id: "task:s1", url: "", title: "")
        let service = PaneChatFixture()
        context.configureWorkspace(factory: NativeWorkspaceFeatureFactory(), service: service)
        let model = try #require(context.workspaceViewModel)
        service.state.session = session()
        service.shells = ["t1": shell("t1"), "t2": shell("t2")]
        let first = context.openChat(thread: "t1"), second = context.openChat(thread: "t2")
        model.preparePaneChat(first); model.preparePaneChat(second)
        let closing = try #require(model.paneChat(for: first))
        let closingPage = try #require(closing.chat?.page)
        context.close(.tool(first))
        #expect(closing.retired && closingPage.retired && model.paneChat(for: first) == nil, "closed with its tab")
        closing.show(chat: try #require(service.makePaneChat(threadID: "t1", in: context)))
        #expect(closing.chat == nil, "retired is terminal")

        let staying = try #require(model.paneChat(for: second))
        let stayingPage = try #require(staying.chat?.page)
        await viewer.remove(id: "task:s1")
        #expect(staying.retired && stayingPage.retired, "closed with its session")
        model.preparePaneChat(second)
        #expect(model.paneChat(for: second) == nil, "and never made again")
    }
}
