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
    var newChatProjects = 0
    var created: [ChatThreadShell] = []
    var chatsMade = 0
    var connected = true
    let chat = NewTaskChat()
    func newSessionComposer(for projectID: String) -> ProjectComposerModel? { composers.append(projectID); return nil }
    func newSessionNewProject(forChat: Bool) { if forChat { newChatProjects += 1 } else { newProjects += 1 } }
    func newSessionChat(agent: String?) -> NewChatViewModel? {
        guard connected else { return nil }
        chatsMade += 1
        return NativeChatFeatureFactory().newChat(agent: agent, service: chat)
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

@MainActor @Test func chatSideStartsInNoProjectAndWorksInAProjectsFolderOncePicked() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        #expect(model.chatProjectID == nil && chat.standalone, "a chat starts in no project")
        await chat.load()
        chat.prompt = "What does the poller do?"

        model.chooseChatProject("p")
        #expect(chat.projectID == "p" && chat.projectName == "P" && chat.folder == "/tmp")
        #expect(!chat.canStart, "Start waits for the project folder's models")
        await chat.modelsLoad?.value
        #expect(chat.canStart && chat.askPlaceholder == "Ask Claude about this project")
        model.chooseChatProject(nil)
        #expect(chat.standalone && chat.folder.isEmpty, "No Project goes back to a scratch folder")
        model.chooseChatProject("gone")
        #expect(chat.standalone && model.chatProjectID == nil, "a project not listed is not picked")

        // Kept by the form made anew on reconnect, and the chat is made in the project's folder.
        model.chooseChatProject("p")
        await chat.modelsLoad?.value
        model.chatServiceChanged()
        let again = try #require(model.chat)
        #expect(again !== chat && again.projectID == "p" && again.folder == "/tmp")
        await again.load()
        await again.start()
        let create = try #require(runtime.chat.commands.first)
        #expect(create["projectId"]?.string == "p" && create["workingDirectory"]?.string == "/tmp")
        #expect(create["worktreePath"] == .null, "no worktree, no branch")
        #expect(model.chat?.projectID == "p", "the next chat starts in the same project")
    }
}

/// The page alone says where the chat works: a project renamed is named anew, and one that leaves
/// the list is no longer the pick when it returns.
@MainActor @Test func theChatFollowsItsProjectAndForgetsOneThatLeft() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()

        model.chooseChatProject("p")
        model.update(projects: [Project(id: "p", name: "Renamed", repo: "", color: nil, workspace: "/tmp")])
        #expect(chat.projectName == "Renamed" && chat.folder == "/tmp")

        model.update(projects: [])
        #expect(chat.standalone && chat.folder.isEmpty && model.chatProjectID == nil, "the project left")
        model.update(projects: [local])
        #expect(chat.standalone, "and the chat does not go back to it by itself")
    }
}

/// Only the Chat side's own New Project moves the chat: New Task opened on a project (⌘N, the
/// sidebar) leaves it where the person put it.
@MainActor @Test func onlyTheChatsOwnNewProjectMovesTheChat() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        model.start(in: "p")
        #expect(chat.standalone && model.chatProjectID == nil, "New Task opened on a project keeps No Project")
        model.start(in: "p", agent: .claude)
        #expect(model.mode == .task && model.chatProjectID == nil)

        model.setMode(.chat)
        model.newChatProject()
        model.newProject()
        #expect(runtime.newChatProjects == 1 && runtime.newProjects == 1, "the chat's chip says it is the chat's")
    }
}

/// A project picked with no form there (the chat backend not connected) is the next form's.
@MainActor @Test func aProjectPickedWhileDisconnectedIsTheNextChats() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        runtime.connected = false
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        #expect(model.chat == nil)
        model.chooseChatProject("p")
        runtime.connected = true
        model.chatServiceChanged()
        #expect(model.chat?.projectID == "p" && model.chat?.folder == "/tmp")
    }
}

/// With no agent to read models for, a move leaves Start as it was rather than waiting for ever,
/// and an error that is not the models' read stays.
@MainActor @Test func aMoveWithNoUsableAgentDoesNotHoldStart() async throws {
    try await withCleanNewTaskDefaults {
        let root = root(), runtime = NewSessionRuntimeFixture()
        let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
        root.navigate(to: .newSession)
        model.update(projects: [local])
        model.setMode(.chat)
        let chat = try #require(model.chat)
        await chat.load()
        chat.agent = nil
        await chat.modelsLoad?.value
        model.chooseChatProject("p")
        #expect(!chat.loadingModels && chat.projectID == "p")
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
