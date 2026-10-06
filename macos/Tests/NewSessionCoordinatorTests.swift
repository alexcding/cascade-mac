import Foundation
import Testing
@testable import Cascade

/// A chat service whose dispatched commands are kept; a create with no folder is answered with the
/// scratch folder the backend would make.
private final class NewTaskChat: ChatServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [JSONValue] = []
    var commands: [JSONValue] { lock.withLock { _commands } }
    var conversation: String?
    static let scratch = "/data/chat/workspaces/"

    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "chat.providerStatuses":
            return [["provider": "claudeAgent", "available": true, "models": [["slug": "opus", "isDefault": true]]],
                    ["provider": "codex", "available": true, "models": [["slug": "gpt-5", "isDefault": true]]]]
        case "orchestration.dispatchCommand":
            let command = params["command"] ?? .null
            lock.withLock { _commands.append(command) }
            if command["type"] == "thread.create", command["workingDirectory"] == .null {
                return ["sequence": 1, "workingDirectory": .string(Self.scratch + (command["threadId"]?.string ?? ""))]
            }
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
    var chatsMade = 0
    var connected = true
    var picked: String? = "/picked"
    let chat = NewTaskChat()
    func newSessionComposer(for projectID: String) -> ProjectComposerModel? { composers.append(projectID); return nil }
    func newSessionNewProject() { newProjects += 1 }
    func newSessionChat(agent: String?) -> NewChatViewModel? {
        guard connected else { return nil }
        chatsMade += 1
        return NativeChatFeatureFactory().newChat(agent: agent, service: chat, chooseFolder: { [weak self] _ in self?.picked })
    }
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
        #expect(model.chat == nil && runtime.chatsMade == 0, "the Task side builds no chat")
        model.setMode(.chat)
        #expect(model.mode == .chat && runtime.chatsMade == 1)
        #expect(model.chat?.projectID == nil && model.chat?.standalone == true, "a chat belongs to no project")
        #expect(NewSessionViewModel().mode == .chat, "the choice is kept for the next launch")
        model.setMode(.task)
        #expect(NewSessionViewModel().mode == .task)

        // A Start link holds a task: it shows the Task side, and remembers nothing.
        model.setMode(.chat)
        model.start(in: "p", text: "https://example.com/pull/1")
        #expect(model.mode == .task && NewSessionViewModel().mode == .chat)
    }
}

@MainActor @Test func chatSideStartsAChatOfNoProjectInAScratchFolderAndGoesToIt() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()
        #expect(chat.agent == "claude" && chat.model == "opus" && !chat.canStart, "nothing typed yet")
        #expect(chat.folder.isEmpty && chat.askPlaceholder == "Ask Claude anything")
        #expect(!chat.offersKnowledge, "the session knowledge is a pane chat's alone")
        chat.prompt = "What does the poller do?"
        #expect(chat.canStart, "no folder is needed")
        await chat.start()

        let commands = runtime.chat.commands
        #expect(commands.map { $0["type"]?.string } == ["thread.create", "thread.turn.start"])
        let create = try #require(commands.first)
        #expect(create["projectId"]?.string == ChatProject.standalone && create["workingDirectory"] == .null)
        #expect(create["worktreePath"] == .null && create["knowledgeSource"] == nil)
        let thread = try #require(create["threadId"]?.string)
        #expect(commands.last?["threadId"]?.string == thread)
        #expect(runtime.created.map(\.id) == [thread], "the list hears of it")
        #expect(runtime.created.first?.cwd == NewTaskChat.scratch + thread, "in the folder the backend made")
        #expect(root.selection == .chat(thread), "the window goes to the chat")
        #expect(chat.retired && model.chat !== chat && model.chat?.prompt == "", "a fresh form for the next chat")
    }
}

/// The folder logic stands for a control to come: a picked folder is used instead of a scratch one.
@MainActor @Test func chatSideWorksInAPickedFolderWhenOneIsChosen() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()
        await chat.changeFolder()
        #expect(chat.folder == "/picked" && chat.askPlaceholder == "Ask Claude about this folder")

        // Cancelling the panel keeps the folder; clearing it goes back to a scratch folder.
        runtime.picked = nil
        await chat.changeFolder()
        #expect(chat.folder == "/picked")
        await chat.clearFolder()
        #expect(chat.folder.isEmpty)
        runtime.picked = "/picked"
        await chat.changeFolder()

        // A form made again on reconnect keeps the folder and what was typed.
        chat.prompt = "carried over"
        model.chatServiceChanged()
        let again = try #require(model.chat)
        #expect(again !== chat && again.folder == "/picked" && again.prompt == "carried over")
        await again.load()
        await again.start()
        let create = try #require(runtime.chat.commands.first)
        #expect(create["projectId"]?.string == ChatProject.standalone && create["workingDirectory"]?.string == "/picked")
        #expect(runtime.created.first?.cwd == "/picked")
    }
}

@MainActor @Test func withNoProjectsTheChatSideStartsAChatWithoutAFolder() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [])
        #expect(model.mode == .task && model.chat == nil)
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()
        chat.prompt = "What is 2+2?"
        #expect(chat.standalone && chat.folder.isEmpty && chat.canStart)
        await chat.start()
        let create = try #require(runtime.chat.commands.first)
        #expect(create["projectId"]?.string == ChatProject.standalone && create["workingDirectory"] == .null)
        #expect(root.selection == .chat(try #require(create["threadId"]?.string)))
    }
}

@MainActor @Test func theChatSideFollowsTheBackendAndARetiredNewTaskChangesNothing() async {
    await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        model.update(projects: [local])
        model.setMode(.chat)
        #expect(model.chat != nil)

        // Not connected: no form, until the backend comes.
        runtime.connected = false
        model.chatServiceChanged()
        #expect(model.chat == nil)
        runtime.connected = true
        model.chatServiceChanged()
        #expect(model.chat?.standalone == true)

        model.retire()
        #expect(model.chat == nil)
        model.setMode(.task)
        #expect(model.mode == .chat, "a retired New Task changes nothing")
    }
}
