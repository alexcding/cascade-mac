import Foundation
import Testing
@testable import Cascade

/// A chat service whose dispatched commands are kept; `conversation` is what a knowledge check finds.
private final class NewTaskChat: ChatServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [JSONValue] = []
    var commands: [JSONValue] { lock.withLock { _commands } }
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
            return conversation.map { ["conversationId": .string($0)] } ?? .null
        default: return .null
        }
    }
}

@MainActor private final class NewSessionRuntimeFixture: NewSessionCoordinating {
    var composers: [String] = []
    var newProjects = 0
    var created: [ChatThreadShell] = []
    var chatPlaces: [NewSessionViewModel.ChatPlace] = []
    var connected = true
    var picked: String? = "/picked"
    var sources: [NewChatViewModel.KnowledgeSource] = []
    let chat = NewTaskChat()
    func newSessionComposer(for projectID: String) -> ProjectComposerModel? { composers.append(projectID); return nil }
    func newSessionNewProject() { newProjects += 1 }
    func newSessionChat(in place: NewSessionViewModel.ChatPlace, agent: String?) -> NewChatViewModel? {
        guard connected else { return nil }
        chatPlaces.append(place)
        switch place {
        case .project(let id):
            let model = NewChatViewModel(projectID: id, projectName: "P", folder: "/tmp", service: chat, agent: agent)
            model.knowledgeSourcesProvider = { [weak self] in self?.sources ?? [] }
            return model
        case .folder(let folder):
            return NewChatViewModel(projectID: nil, projectName: nil, folder: folder, service: chat, agent: agent)
        }
    }
    func newSessionChooseChatFolder(from start: String?) async -> String? { picked }
    func newSessionChatCreated(_ shell: ChatThreadShell) { created.append(shell) }
}

/// Runs `body` with New Task's remembered side and project cleared, and puts back what was there.
@MainActor private func withCleanNewTaskDefaults(_ body: () async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let keys = [NewSessionViewModel.modeKey, "newSessionProject"]
    let saved = keys.map { defaults.object(forKey: $0) }
    keys.forEach { defaults.removeObject(forKey: $0) }
    defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    try await body()
}

@MainActor private func root() -> AppCoordinator { AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })) }
private let local = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp")

@MainActor @Test func newTaskAsksForNewProjectOnlyWhileItIsOnScreen() {
    let root = root(), runtime = NewSessionRuntimeFixture()
    let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    #expect(root.newSession === model)
    root.navigate(to: .overview)
    model.newProject()
    #expect(runtime.newProjects == 0, "New Task is not on screen")
    root.navigate(to: .newSession)
    model.newProject()
    #expect(runtime.newProjects == 1)
    model.update(projects: [local])
    #expect(runtime.composers == ["p"], "The picked project's composer is asked for")
}

@MainActor @Test func aReplacedNewTaskIsRetiredForGood() {
    let root = root(), runtime = NewSessionRuntimeFixture()
    let first = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    let second = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    #expect(first.retired && !second.retired && root.newSession === second)
    root.navigate(to: .newSession)
    first.newProject(); first.update(projects: [local])
    #expect(runtime.newProjects == 0 && runtime.composers.isEmpty, "A retired New Task asks for nothing")
}

// MARK: - The Chat side

@MainActor @Test func newTaskRemembersTaskOrChat() async {
    await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        #expect(model.mode == .task, "Task until Chat is chosen")
        model.update(projects: [local])
        #expect(model.chat == nil && runtime.chatPlaces.isEmpty, "the Task side builds no chat")
        model.setMode(.chat)
        #expect(model.mode == .chat && model.chat?.projectID == "p" && runtime.chatPlaces == [.project("p")])
        #expect(NewSessionViewModel().mode == .chat, "the choice is kept for the next launch")
        model.setMode(.task)
        #expect(NewSessionViewModel().mode == .task)

        // A Start link holds a task: it shows the Task side, and remembers nothing.
        model.setMode(.chat)
        model.start(in: "p", text: "https://example.com/pull/1")
        #expect(model.mode == .task && NewSessionViewModel().mode == .chat)
    }
}

@MainActor @Test func chatSideStartsTheChatSendsTheFirstMessageAndGoesToIt() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()
        #expect(chat.agent == "claude" && chat.model == "opus" && !chat.canStart, "nothing typed yet")
        #expect(chat.askPlaceholder == "Ask Claude about this project")
        chat.prompt = "What does the poller do?"
        await chat.start()

        let commands = runtime.chat.commands
        #expect(commands.map { $0["type"]?.string } == ["thread.create", "thread.turn.start"])
        let create = try #require(commands.first)
        #expect(create["projectId"]?.string == "p" && create["workingDirectory"]?.string == "/tmp")
        #expect(create["worktreePath"]?.string == nil && create["knowledgeSource"] == nil)
        let thread = try #require(create["threadId"]?.string)
        #expect(commands.last?["threadId"]?.string == thread)
        #expect(runtime.created.map(\.id) == [thread], "the list hears of it")
        #expect(root.selection == .chat(thread), "the window goes to the chat")
        #expect(chat.retired && model.chat !== chat && model.chat?.prompt == "", "a fresh form for the next chat")
    }
}

@MainActor @Test func chatSideNoProjectStartsAStandaloneChatInThePickedFolder() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        model.chat?.prompt = "carried over"
        await model.chooseNoProject()
        #expect(model.place == .folder("/picked"))
        let chat = try #require(model.chat)
        #expect(chat.standalone && chat.folder == "/picked" && chat.prompt == "carried over" && !chat.offersKnowledgeSources)
        await chat.load()
        await chat.start()
        let create = try #require(runtime.chat.commands.first)
        #expect(create["projectId"]?.string == ChatProject.standalone && create["workingDirectory"]?.string == "/picked")

        // Cancelling the panel keeps the place; picking a project goes back to it.
        runtime.picked = nil
        await model.chooseNoProject()
        #expect(model.place == .folder("/picked"))
        model.choose("p")
        #expect(model.place == .project("p") && model.chat?.projectID == "p")
    }
}

@MainActor @Test func chatSideKnowledgeIsASessionPickedAndTheChatWorksInItsWorktree() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)

        // No session with an agent conversation: the chip is there, disabled with its reason.
        let none = try #require(model.chat)
        await none.load()
        #expect(none.offersKnowledgeSources && !none.canChooseKnowledge)
        #expect(none.knowledgeSourcesReason == "No session of this project has an agent conversation yet.")

        runtime.sources = [.init(id: "s1", title: "feature", cli: "claude", conversationID: "c1", worktree: "/tmp/wt/s1")]
        model.chatServiceChanged()
        let chat = try #require(model.chat)
        await chat.load()
        #expect(chat.canChooseKnowledge && chat.knowledgeSourceID == nil && !chat.includeKnowledge, "off by default")

        // A session whose agent has nothing on disk is not picked, and says so.
        await chat.chooseKnowledge("s1")
        #expect(chat.knowledgeSourceID == nil && chat.folder == "/tmp" && chat.knowledgeNote == "feature’s agent has no conversation to start from.")

        runtime.chat.conversation = "c1"
        await chat.chooseKnowledge("s1")
        #expect(chat.chosenKnowledgeSource?.id == "s1" && chat.includeKnowledge && chat.folder == "/tmp/wt/s1" && chat.knowledgeNote == nil)
        chat.prompt = "Pick up where it left off"
        await chat.start()
        let create = try #require(runtime.chat.commands.first)
        #expect(create["workingDirectory"]?.string == "/tmp/wt/s1", "in the session's worktree, where the backend takes the knowledge")
        #expect(create["worktreePath"]?.string == nil, "not a pane's chat: listed under its project")
        #expect(create["knowledgeSource"] == ["provider": "claudeAgent", "conversationId": "c1"])

        // Picking none again goes back to the project's folder.
        let next = try #require(model.chat)
        await next.load()
        await next.chooseKnowledge("s1")
        await next.chooseKnowledge(nil)
        #expect(next.folder == "/tmp" && !next.includeKnowledge && next.knowledgeSourceID == nil)
    }
}

@MainActor @Test func aProjectsNewChatOpensNewTaskOnTheChatSide() async {
    await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        let other = Project(id: "q", name: "Q", repo: "", color: nil, workspace: "/other")
        model.update(projects: [local, other])
        model.startChat(in: "q")
        #expect(model.mode == .chat && model.projectID == "q" && model.chat?.projectID == "q")
        #expect(NewSessionViewModel().mode == .task, "an ask for a chat is not the person's choice of side")

        // Not connected: no form, until the backend comes.
        runtime.connected = false
        model.chatServiceChanged()
        #expect(model.chat == nil)
        runtime.connected = true
        model.chatServiceChanged()
        #expect(model.chat?.projectID == "q")

        model.retire()
        #expect(model.chat == nil)
        model.setMode(.task)
        #expect(model.mode == .chat, "a retired New Task changes nothing")
    }
}
