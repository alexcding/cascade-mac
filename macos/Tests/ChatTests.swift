import AppKit
import Foundation
import Testing
import WebKit

// MARK: - Fixtures

/// The backend's chat route, answering by method; every request it gets is kept.
private actor ChatTransport: BackendTransport {
    private(set) var bodies: [JSONValue] = []
    var paths: [String] = []

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        paths.append(url.path)
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("{}".utf8))
        bodies.append(body)
        let (status, reply): (Int, String) = switch body["method"]?.string {
        case "chat.listThreads":
            (200, #"{"result":[{"id":"t1","projectId":"p","title":"Fix the build","modelSelection":{"provider":"claudeAgent","model":"opus"},"runtimeMode":"approval-required","workingDirectory":"/work","createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-02T00:00:00.000Z","archivedAt":null,"latestTurn":{"turnId":"u","state":"running","requestedAt":"x","startedAt":null,"completedAt":null,"assistantMessageId":null},"session":null,"hasPendingApprovals":true,"branch":null,"worktreePath":null,"interactionMode":"default"},{"id":42},{"id":"t2","projectId":"cascade-standalone","title":"","modelSelection":{"provider":"codex","model":"gpt-5"},"worktreePath":"/elsewhere","createdAt":"2026-10-03T00:00:00.000Z","archivedAt":"2026-10-04T00:00:00.000Z"}]}"#)
        case "orchestration.dispatchCommand": (200, #"{"result":{"sequence":7}}"#)
        case "chat.providerStatuses": (200, #"{"result":[{"provider":"claudeAgent","status":"ready","available":true,"authStatus":"authenticated","checkedAt":"x"}]}"#)
        case "provider.listModels": (200, #"{"result":{"models":[{"slug":"sonnet","name":"Sonnet"},{"slug":"opus","name":"Opus","isDefault":true}]}}"#)
        case "unknown.method": (400, #"{"error":{"message":"No such method","code":"unavailable"}}"#)
        default: (500, #"{"error":"exploded"}"#)
        }
        return (Data(reply.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private func chatService(_ transport: ChatTransport) throws -> any ChatServing {
    // Through the app's own factory, as `AppViewModel` makes it.
    NativeBackendFeatureFactory().chat(api: try APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: transport))
}

/// A chat service whose every call is answered by a closure, for the store and the new-chat sheet.
private struct ScriptedChat: ChatServing {
    let answer: @Sendable (String, JSONValue) async throws -> JSONValue
    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue { try await answer(method, params) }
}

/// The page's backend: requests answered at once, the snapshot held until the test lets it go.
private actor PageBackend: ChatPageBackend {
    private(set) var calls: [String] = []
    private(set) var params: [JSONValue] = []
    /// The snapshot read fails, as a backend that went away does.
    var failsSnapshot = false
    private var holding = false
    private var gate: CheckedContinuation<Void, Never>?
    var snapshotValue: JSONValue = ["snapshotSequence": 2, "thread": ["id": "t1", "messages": []]]

    func hold() { holding = true }
    func failSnapshots(_ value: Bool) { failsSnapshot = value }
    func release() { holding = false; gate?.resume(); gate = nil }

    func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(method)
        self.params.append(params)
        if method == "provider.compactThread" { throw ChatRPCError(message: "Not now", code: "invalid") }
        return ["echo": params]
    }
    func providers() async throws -> JSONValue { [["provider": "claudeAgent", "available": true]] }
    func snapshot(threadID: String) async throws -> JSONValue {
        if holding { await withCheckedContinuation { gate = $0 } }
        if failsSnapshot { throw ChatRPCError(message: "gone") }
        return snapshotValue
    }
}

@MainActor private final class Outputs {
    var values: [ChatPageOutput] = []
    var pushes: [(String, JSONValue)] {
        values.compactMap { if case .push(let channel, let value) = $0 { (channel, value) } else { nil } }
    }
    var thread: [JSONValue] { pushes.filter { $0.0 == "thread" }.map(\.1) }
    var replies: [(String, JSONValue)] {
        values.compactMap { if case .reply(let id, let value) = $0 { (id, value) } else { nil } }
    }
}

/// Waits, a turn at a time, for what a task under test is about to do.
@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

private func shell(_ id: String, project: String, created: String, archived: Bool = false) -> ChatThreadShell {
    ChatThreadShell(id: id, projectId: project, title: id, modelSelection: .init(provider: "claudeAgent", model: "opus"),
                    workingDirectory: "/work/\(id)", createdAt: created, archivedAt: archived ? "2026-10-05T00:00:00.000Z" : nil)
}

private func pageContext(_ id: String = "t1") -> ChatPageContext {
    ChatPageContext(threadId: id, projectId: "p", cwd: "/work", projectName: "Project", locale: "en-US", homeDir: "/Users/me")
}

// MARK: - Subagent threads

@MainActor @Test func subagentThreadsAreKeptButNotListed() async throws {
    var child = shell("subagent:parent:toolu_1", project: "p", created: "2026-02-02")
    child.parentThreadId = "parent"
    let listing: JSONValue = try .from([shell("parent", project: "p", created: "2026-02-01"), child,
                                        shell("loose", project: ChatProject.standalone, created: "2026-01-15")].map(Encoded.init))
    let store = ChatListStore()
    store.connect(ScriptedChat { _, _ in listing })
    await store.settle()

    // The backend's shell names the parent; the store keeps the child so its parent's page can open it.
    let decoded = try JSONValue.from(["id": "c", "projectId": "p", "title": "List files [general-purpose]", "parentThreadId": "parent"])
        .decode(ChatThreadShell.self)
    #expect(decoded.subagent && decoded.parentThreadId == "parent")
    #expect(store.shell(child.id)?.subagent == true && store.shell("parent")?.subagent == false)
    // Lists (sidebar, Projects) leave it out; routing, which takes the app to it, does not.
    #expect(store.visible().map(\.id) == ["parent", "loose"])
    #expect(store.grouped(projectIDs: ["p"]).byProject["p"]?.map(\.id) == ["parent"])
    #expect(store.visible(includeSubagents: true).map(\.id) == [child.id, "parent", "loose"])
}

// MARK: - ChatService

@MainActor @Test func chatServiceSendsMethodsAndDecodesShells() async throws {
    let transport = ChatTransport()
    let service = try chatService(transport)

    let shells = try await service.listThreads()
    // The unreadable row is left out rather than losing the list.
    #expect(shells.map(\.id) == ["t1", "t2"])
    let first = try #require(shells.first)
    #expect(first.cwd == "/work" && first.cli == "claude" && first.working && first.needsInput && !first.archived)
    #expect(shells[1].cwd == "/elsewhere" && shells[1].cli == "codex" && shells[1].archived && shells[1].standalone)
    #expect(shells[1].label == String(localized: "New Chat"))

    _ = try await service.listThreads(projectID: "p")
    let created = try await service.createThread(projectID: "p", cwd: "/work", provider: "claudeAgent", model: "opus", id: "new-thread",
                                                 now: Date(timeIntervalSince1970: 0))
    #expect(created == ChatCreated(id: "new-thread", workingDirectory: "/work"))
    try await service.renameThread("t1", to: "Renamed")
    try await service.archiveThread("t1")
    try await service.deleteThread("t1")
    let models = try await service.listModels(provider: "claudeAgent", cwd: "/work")
    #expect(models.map(\.slug) == ["sonnet", "opus"] && models[1].isDefault == true)

    let bodies = await transport.bodies
    #expect(await transport.paths.allSatisfy { $0 == Routes.CHAT_RPC })
    #expect(bodies[0] == ["method": "chat.listThreads", "params": [:]])
    #expect(bodies[1]["params"] == ["projectId": "p"])
    let create = try #require(bodies[2]["params"]?["command"])
    #expect(bodies[2]["method"] == "orchestration.dispatchCommand")
    #expect(create["type"] == "thread.create" && create["threadId"] == "new-thread" && create["projectId"] == "p")
    #expect(create["modelSelection"] == ["provider": "claudeAgent", "model": "opus"])
    #expect(create["runtimeMode"] == "approval-required" && create["workingDirectory"] == "/work")
    #expect(create["title"] == .string(ChatProject.untitled) && create["createdAt"] == "1970-01-01T00:00:00.000Z")
    #expect(create["commandId"]?.string?.isEmpty == false && create["branch"] == .null)
    let rename = try #require(bodies[3]["params"]?["command"])
    #expect(rename["type"] == "thread.meta.update" && rename["threadId"] == "t1" && rename["title"] == "Renamed")
    #expect(bodies[4]["params"]?["command"]?["type"] == "thread.archive")
    #expect(bodies[5]["params"]?["command"]?["type"] == "thread.delete")
    #expect(bodies[6]["params"] == ["provider": "claudeAgent", "cwd": "/work"])

    // A refusal keeps its message and code; a bare router error its text.
    await #expect(throws: ChatRPCError(message: "No such method", code: "unavailable")) {
        try await service.rpc("unknown.method", params: [:])
    }
    await #expect(throws: ChatRPCError(message: "exploded")) { try await service.rpc("other", params: [:]) }
}

@Test func chatEventsDecodeFromTheBackendStream() throws {
    let thread = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"chat-thread","threadId":"t1","events":[{"sequence":3,"type":"thread.message-sent","payload":{"ok":true}}]}"#.utf8))
    #expect(thread.threadId == "t1" && thread.events?.first?["sequence"] == 3 && thread.events?.first?["payload"]?["ok"] == true)
    let shellEvent = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"chat-shell","shell":{"id":"t1","projectId":"p","title":"Named"}}"#.utf8))
    #expect(try shellEvent.shell?.decode(ChatThreadShell.self).title == "Named")
    let removed = try JSONDecoder().decode(ServerEvent.self, from: Data(#"{"type":"chat-removed","threadId":"t9"}"#.utf8))
    #expect(removed.threadId == "t9" && removed.events == nil)
}

// MARK: - ChatListStore

@MainActor @Test func chatListGroupsByProjectAndFollowsEvents() async throws {
    let listing: JSONValue = try .from([shell("old", project: "p", created: "2026-01-01"), shell("new", project: "p", created: "2026-02-01"),
                                        shell("loose", project: ChatProject.standalone, created: "2026-01-15"),
                                        shell("orphan", project: "gone", created: "2026-01-10"),
                                        shell("shelved", project: "p", created: "2026-03-01", archived: true)].map(Encoded.init))
    let store = ChatListStore()
    var loads = 0
    store.onLoad = { loads += 1 }
    store.connect(ScriptedChat { method, _ in
        #expect(method == "chat.listThreads")
        return listing
    })
    await store.settle()
    #expect(store.loaded && loads == 1)

    let grouped = store.grouped(projectIDs: ["p"])
    // Newest first; archived left out; a chat of a project that is gone goes with the standalone ones.
    #expect(grouped.byProject["p"]?.map(\.id) == ["new", "old"])
    #expect(grouped.standalone.map(\.id) == ["loose", "orphan"])
    #expect(store.grouped(projectIDs: ["p"], includeArchived: true).byProject["p"]?.map(\.id) == ["shelved", "new", "old"])

    // `chat-shell` updates or adds; `chat-removed` takes it out.
    var renamed = shell("old", project: "p", created: "2026-01-01")
    renamed.title = "Renamed"
    store.receive(shell: try .from(Encoded(renamed)))
    #expect(store.shell("old")?.title == "Renamed")
    store.receive(shell: ["id": 3])
    #expect(store.shells.count == 5)
    store.remove("loose")
    #expect(store.grouped(projectIDs: ["p"]).standalone.map(\.id) == ["orphan"])

    // What an event said while a listing was on its way outlives the older listing.
    let gate = AsyncStream<Void>.makeStream()
    store.connect(ScriptedChat { _, _ in
        for await _ in gate.stream { break }
        return listing
    })
    store.remove("new")
    store.receive(shell("fresh", project: "p", created: "2026-04-01"))
    gate.continuation.yield()
    await store.settle()
    #expect(store.shell("new") == nil && store.shell("fresh") != nil && store.shell("loose") != nil)
    #expect(loads == 2)
}

/// `ChatThreadShell` is only decoded by the app; the fixtures encode the fields it reads.
private struct Encoded: Encodable {
    let shell: ChatThreadShell
    init(_ shell: ChatThreadShell) { self.shell = shell }
    func encode(to encoder: any Encoder) throws {
        var object: [String: JSONValue] = ["id": .string(shell.id), "projectId": .string(shell.projectId), "title": .string(shell.title)]
        if let selection = shell.modelSelection { object["modelSelection"] = ["provider": .string(selection.provider), "model": .string(selection.model)] }
        if let folder = shell.workingDirectory { object["workingDirectory"] = .string(folder) }
        if let created = shell.createdAt { object["createdAt"] = .string(created) }
        if let archived = shell.archivedAt { object["archivedAt"] = .string(archived) }
        if let parent = shell.parentThreadId { object["parentThreadId"] = .string(parent) }
        try JSONValue.object(object).encode(to: encoder)
    }
}

// MARK: - ChatPageModel

@MainActor @Test func chatPageForwardsRequestsAndRepliesWithTheirID() async throws {
    let backend = PageBackend()
    let outputs = Outputs()
    var copied: [String] = []
    let page = ChatPageModel(context: pageContext(), backend: backend, copy: { copied.append($0) }, output: { outputs.values.append($0) })
    #expect(page.webView == nil)

    page.receive(message: ["kind": "request", "id": "7", "method": "provider.listModels", "params": ["provider": "codex"]])
    page.receive(message: ["kind": "request", "id": "8", "method": "provider.compactThread", "params": [:]])
    await until { outputs.replies.count == 2 }
    let replies = Dictionary(outputs.replies, uniquingKeysWith: { first, _ in first })
    #expect(replies["7"] == ["ok": true, "result": ["echo": ["provider": "codex"]]])
    #expect(replies["8"] == ["ok": false, "error": ["message": "Not now", "code": "invalid"]])
    #expect(await backend.calls.sorted() == ["provider.compactThread", "provider.listModels"])
    #expect(ChatPageOutput.reply(id: "7", ["ok": true]).script == #"window.nativeChat.reply("7", {"ok":true})"#)

    // Events the app handles itself.
    var events: [ChatPageEvent] = []
    page.onEvent = { events.append($0) }
    page.receive(message: ["kind": "event", "name": "openLink", "payload": ["url": "https://example.com"]])
    page.receive(message: ["kind": "event", "name": "openLink", "payload": ["url": "file:///etc/passwd"]])
    page.receive(message: ["kind": "event", "name": "copy", "payload": ["text": "copied"]])
    #expect(events == [.openLink(URL(string: "https://example.com")!)])
    #expect(copied == ["copied"])
    // WebKit's Foundation objects are read as JSON, a boolean staying a boolean.
    page.receive(["kind": "request", "id": "9", "method": "x", "params": ["flag": true]] as [String: Any])
    await until { outputs.replies.count == 3 }
    #expect(outputs.replies.last?.1["result"]?["echo"] == ["flag": true])
}

@MainActor @Test func chatPageHoldsEventsUntilTheSnapshotIsIn() async throws {
    let backend = PageBackend()
    await backend.hold()
    let outputs = Outputs()
    let page = ChatPageModel(context: pageContext(), backend: backend, output: { outputs.values.append($0) })

    // Before the page is up, nothing goes to it.
    page.receiveThreadEvents([["sequence": 1]])
    #expect(outputs.values.isEmpty)

    page.receive(message: ["kind": "event", "name": "ready", "payload": [:]])
    #expect(outputs.pushes.first?.0 == "context")
    #expect(outputs.pushes.first?.1["threadId"] == "t1" && outputs.pushes.first?.1["readOnly"] == false)
    await until { outputs.pushes.contains { $0.0 == "providers" } }
    page.receiveThreadEvents([["sequence": 2], ["sequence": 3]])
    #expect(outputs.thread.isEmpty)

    await backend.release()
    await until { !outputs.thread.isEmpty }
    // The snapshot first; then only what it does not already include (it ends at 2).
    #expect(outputs.pushes.map(\.0) == ["context", "providers", "thread", "thread"])
    #expect(outputs.thread[0]["kind"] == "snapshot" && outputs.thread[0]["snapshot"]?["snapshotSequence"] == 2)
    #expect(outputs.thread[1] == ["kind": "event", "event": ["sequence": 3]])

    // Live: straight through.
    page.receiveThreadEvents([["sequence": 4]])
    #expect(outputs.thread.last == ["kind": "event", "event": ["sequence": 4]])

    // The window's appearance goes to the page as a new context.
    page.setAppearance(.dark)
    #expect(outputs.pushes.last?.0 == "context" && outputs.pushes.last?.1["appearance"] == "dark")
}

/// A folder with a file in it, a file beside it and a link out of it, for the confinement tests.
private struct ChatFolder {
    let root: URL
    let folder: String
    let inside: String
    let outside: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-files-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work/src")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: work.appendingPathComponent("main.swift"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("work/escape").path,
                                                   withDestinationPath: root.appendingPathComponent("secret.txt").path)
        // The temporary folder is itself behind a link (/var → /private/var): the real paths are compared.
        folder = root.appendingPathComponent("work").path
        inside = ChatFileAccess.real(work.appendingPathComponent("main.swift").path)!
        outside = ChatFileAccess.real(root.appendingPathComponent("secret.txt").path)!
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The page draws what the agent wrote: a file it asks to open or reveal is followed only inside
/// the chat's folder, after `..` and links are resolved.
@MainActor @Test func chatPageOpensOnlyFilesInsideItsFolder() async throws {
    let files = try ChatFolder()
    defer { files.remove() }
    var context = pageContext()
    context.cwd = files.folder
    let page = ChatPageModel(context: context, backend: PageBackend(), output: { _ in })
    var events: [ChatPageEvent] = []
    page.onEvent = { events.append($0) }
    func ask(_ name: String, _ path: String) {
        page.receive(message: ["kind": "event", "name": .string(name), "payload": ["path": .string(path), "line": 12]])
    }
    ask("openFile", "src/main.swift")
    ask("revealFile", files.folder + "/src/../src/main.swift")
    ask("openFile", "../secret.txt")
    ask("openFile", files.outside)
    ask("revealFile", "escape")
    ask("openFile", "/etc/hosts")
    ask("openFile", "~/.ssh/id_rsa")
    ask("openFile", "src/missing.swift")
    #expect(events == [.openFile(path: files.inside, line: 12), .revealFile(files.inside)])

    #expect(ChatFileAccess.confined(files.folder, to: files.folder) == ChatFileAccess.real(files.folder))
    #expect(ChatFileAccess.confined("src/main.swift", to: "") == nil, "A chat with no folder opens nothing")
    // A sibling whose name starts with the folder's is not inside it.
    let sibling = files.root.appendingPathComponent("work-other")
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    #expect(ChatFileAccess.confined(sibling.path, to: files.folder) == nil)
}

/// What would run something when opened is shown in Finder instead.
@Test func chatFilesThatWouldRunAreNotOpened() throws {
    let files = try ChatFolder()
    defer { files.remove() }
    #expect(!ChatFileAccess.runsWhenOpened(files.inside))
    #expect(!ChatFileAccess.runsWhenOpened(files.folder), "A plain folder opens in Finder")
    let work = URL(fileURLWithPath: files.folder)
    for name in ["Run.command", "Shell.terminal", "Tool.tool", "install.pkg", "go.sh", "Link.webloc"] {
        let file = work.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        #expect(ChatFileAccess.runsWhenOpened(file.path), "\(name)")
    }
    let app = work.appendingPathComponent("Thing.app/Contents")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    #expect(ChatFileAccess.runsWhenOpened(work.appendingPathComponent("Thing.app").path))
    let binary = work.appendingPathComponent("build-it")
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    #expect(ChatFileAccess.runsWhenOpened(binary.path))
}

/// The page's reads of its folder name the chat, so the backend reads the chat's own folder.
@MainActor @Test func chatPageNamesItsThreadOnFolderReads() async throws {
    let backend = PageBackend()
    let outputs = Outputs()
    let page = ChatPageModel(context: pageContext(), backend: backend, output: { outputs.values.append($0) })
    for (id, method) in [("1", "projects.searchEntries"), ("2", "projects.readFile"), ("3", "projects.resolveWorkspaceFileReferences"),
                         ("4", "provider.listModels")] {
        page.receive(message: ["kind": "request", "id": .string(id), "method": .string(method),
                               "params": ["cwd": "/elsewhere", "threadId": "other"]])
    }
    await until { outputs.replies.count == 4 }
    let calls = await backend.calls, sent = await backend.params
    for (method, params) in zip(calls, sent) {
        let expected: JSONValue = ChatFileAccess.folderMethods.contains(method) ? "t1" : "other"
        #expect(params["threadId"] == expected, "\(method)")
    }
}

/// A snapshot that cannot be read does not hold the thread's events for ever: they go through,
/// and the page, finding a gap, reads the thread itself.
@MainActor @Test func aFailedSnapshotLetsHeldEventsThrough() async throws {
    let backend = PageBackend()
    await backend.failSnapshots(true)
    let outputs = Outputs()
    let page = ChatPageModel(context: pageContext(), backend: backend, output: { outputs.values.append($0) })
    page.receive(message: ["kind": "event", "name": "ready", "payload": [:]])
    page.receiveThreadEvents([["sequence": 3]])
    await until { !outputs.thread.isEmpty }
    #expect(outputs.thread == [["kind": "event", "event": ["sequence": 3]]])
    page.receiveThreadEvents([["sequence": 4]])
    #expect(outputs.thread.last == ["kind": "event", "event": ["sequence": 4]], "Live")

    // The same after a resync.
    page.resync()
    page.receiveThreadEvents([["sequence": 5]])
    await until { outputs.thread.count == 3 }
    #expect(outputs.thread.last == ["kind": "event", "event": ["sequence": 5]])
    page.receiveThreadEvents([["sequence": 6]])
    #expect(outputs.thread.last == ["kind": "event", "event": ["sequence": 6]])
}

/// A failure the page reported is shown until the page takes a push again.
@MainActor @Test func aPageFailureClearsOnTheNextPush() async throws {
    let page = ChatPageModel(context: pageContext(), backend: PageBackend(), output: { _ in })
    page.receive(message: ["kind": "event", "name": "ready", "payload": [:]])
    page.receive(message: ["kind": "event", "name": "error", "payload": ["message": "boom"]])
    #expect(page.failure == "boom")
    page.setAppearance(.dark)
    #expect(page.failure == nil)
}

@MainActor @Test func retiredChatPageSendsAndAnswersNothing() async throws {
    let backend = PageBackend()
    let outputs = Outputs()
    let page = ChatPageModel(context: pageContext(), backend: backend, output: { outputs.values.append($0) })
    page.receive(message: ["kind": "event", "name": "ready", "payload": [:]])
    await until { outputs.thread.count == 1 }
    var events: [ChatPageEvent] = []
    page.onEvent = { events.append($0) }
    page.retire()
    let sent = outputs.values.count

    page.receiveThreadEvents([["sequence": 9]])
    page.receive(message: ["kind": "request", "id": "1", "method": "x", "params": [:]])
    page.receive(message: ["kind": "event", "name": "openLink", "payload": ["url": "https://example.com"]])
    page.receive(message: ["kind": "event", "name": "ready", "payload": [:]])
    page.setAppearance(.dark)
    page.resync()
    try await Task.sleep(for: .milliseconds(30))
    #expect(outputs.values.count == sent && events.isEmpty && page.retired)
    #expect(await backend.calls.isEmpty)
}

// MARK: - New Chat

@MainActor @Test func newChatOffersInstalledAgentsAndCreatesOnTheChosenModel() async throws {
    let commands = CommandLog()
    let model = NewChatViewModel(projectID: "p", projectName: "Project", folder: "/work", service: ScriptedChat { method, params in
        switch method {
        case "chat.providerStatuses":
            return [["provider": "claudeAgent", "available": true, "status": "ready"],
                    ["provider": "codex", "available": false, "status": "error", "message": "codex not found"]]
        case "provider.listModels": return ["models": [["slug": "sonnet"], ["slug": "opus", "isDefault": true]]]
        case "orchestration.dispatchCommand":
            await commands.add(params["command"] ?? .null)
            return ["sequence": 1]
        default: throw ChatRPCError(message: "unexpected \(method)")
        }
    })
    var created: [ChatThreadShell] = []
    model.onAction = { if case .created(let shell) = $0 { created.append(shell) } }
    await model.load()
    await until { model.model != nil }
    #expect(model.agents.map(\.cli) == ["claude", "codex"])
    #expect(model.agents.map(\.usable) == [true, false] && model.agents[1].note == "codex not found")
    #expect(model.agent == "claude" && model.model == "opus" && model.canCreate)

    await model.create()
    let command = try #require(await commands.values.first)
    #expect(command["projectId"] == "p" && command["workingDirectory"] == "/work" && command["modelSelection"]?["model"] == "opus")
    #expect(created.first?.id == command["threadId"]?.string && created.first?.projectId == "p" && created.first?.cli == "claude")

    model.retire()
    await model.create()
    #expect(await commands.values.count == 1)
}

/// New Task's chat needs no folder (the backend makes one) and asks for models with none; a project
/// chat with no folder says so rather than offering a chat that cannot start.
@MainActor @Test func aNewTaskChatNeedsNoFolder() async throws {
    let asked = CommandLog()
    let service = ScriptedChat { method, params in
        switch method {
        case "chat.providerStatuses": return [["provider": "claudeAgent", "available": true, "status": "ready"]]
        case "provider.listModels":
            await asked.add(params["cwd"] ?? .null)
            return ["models": [["slug": "opus"]]]
        default: throw ChatRPCError(message: "unexpected \(method)")
        }
    }
    let model = NativeChatFeatureFactory().newChat(agent: nil, service: service)
    await model.load()
    await until { model.model != nil }
    #expect(model.standalone && model.folder.isEmpty && model.canCreate && !model.missingFolder && !model.offersKnowledge)
    #expect(await asked.values.last == .null, "no cwd")

    let project = NewChatViewModel(projectID: "p", projectName: "Project", folder: "", service: service)
    #expect(project.missingFolder && !project.canCreate)
}

private actor CommandLog {
    private(set) var values: [JSONValue] = []
    func add(_ value: JSONValue) { values.append(value) }
}

// MARK: - Routing

@MainActor private final class ChatRuntimeFixture: ChatCoordinating {
    var made: [String] = []
    var performed: [ChatViewModel.Action] = []
    var available: Set<String> = ["t1", "t2"]
    /// The chats whose screen is made with an archived shell.
    var archived: Set<String> = []
    func makeChatModel(threadID: String) -> ChatViewModel? {
        guard available.contains(threadID) else { return nil }
        made.append(threadID)
        let record = archived.contains(threadID) ? shell(threadID, project: "p", created: "2026-01-01", archived: true) : nil
        return ChatViewModel(threadID: threadID, shell: record, projectName: "Project",
                             page: ChatPageModel(context: pageContext(threadID), backend: PageBackend(), output: { _ in }))
    }
    func performChatAction(_ action: ChatViewModel.Action, threadID: String) { performed.append(action) }
}

@Test func chatDeepLinksRoundTrip() throws {
    let router = CascadeRouter()
    let link = DeepLink(.destination(.chat("3f2a-thread")))
    let url = try #require(router.url(for: link))
    #expect(url.absoluteString == "cascade://app/chats/3f2a-thread")
    #expect(router.deepLink(for: url) == link)
    #expect(router.deepLink(for: URL(string: "cascade://app/chats/a/b")!) == nil)
    #expect(router.deepLink(for: URL(string: "cascade://app/chats")!) == nil)
}

@MainActor @Test func chatSelectionMakesItsScreenAndRetiresItOnLeaving() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ChatRuntimeFixture()
    coordinator.chatRuntime = runtime

    coordinator.navigate(to: .chat("t1"))
    guard case .chatCoordinator(let first) = coordinator.root else { Issue.record("no chat screen: \(coordinator.root)"); return }
    #expect(first.threadID == "t1" && runtime.made == ["t1"])
    #expect(first.canPresent())
    // Rebuilding the root keeps the same screen.
    coordinator.refreshRoot()
    #expect(coordinator.chatCoordinator === first && runtime.made == ["t1"])

    // What the page asks for goes to the app while the chat is the one on screen.
    first.model.openFolder()
    #expect(runtime.performed == [.openFolder("/work")])

    coordinator.navigate(to: .chat("t2"))
    #expect(first.retired && first.model.retired && first.model.page.retired)
    #expect(coordinator.chatCoordinator?.threadID == "t2")
    let second = try #require(coordinator.chatCoordinator)

    // A chat the app cannot show yet is a placeholder, not a screen.
    coordinator.navigate(to: .chat("missing"))
    #expect(second.retired && coordinator.chatCoordinator == nil)
    if case .unavailable = coordinator.root {} else { Issue.record("expected a placeholder") }

    // A deleted chat on screen sends the window back to Projects.
    coordinator.navigate(to: .chat("t1"))
    let third = try #require(coordinator.chatCoordinator)
    coordinator.chatRemoved("t1")
    #expect(coordinator.selection == .overview && third.retired && coordinator.chatCoordinator == nil)
    third.model.openFolder()
    #expect(runtime.performed.count == 1)
}

@MainActor @Test func sidebarListsEveryChatUnderChatsNewestFirstWithItsPlace() {
    let project = Project(id: "p", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
    // No chat: no Chats heading at all, and the project holds no chat rows.
    let none = SidebarEntry.make(projects: [project], sessions: [workspaceSessionForChats("s")])
    #expect(!none.contains { $0.id == SidebarEntry.chatsID })
    #expect(none.first { $0.id == "project:p" }?.children.map(\.id) == ["session:s"])

    // The first chat brings the heading and its row.
    var working = shell("busy", project: "p", created: "2026-02-01")
    working.latestTurn = .init(state: "running")
    let first = SidebarEntry.make(projects: [project], sessions: [workspaceSessionForChats("s")], chats: [working])
    #expect(Array(first.map(\.id).suffix(2)) == [SidebarEntry.chatsID, "chat:busy"])
    #expect(first.first { $0.id == SidebarEntry.chatsID }?.title == "Chats")
    #expect(first.first { $0.id == SidebarEntry.chatsID }?.hoverable == false, "a heading with no +")
    #expect(first.first { $0.id == "project:p" }?.children.map(\.id) == ["session:s"], "project rows show only their sessions")

    // Every chat archived: the heading stays, rowless, so its menu still reaches them.
    let archivedOnly = SidebarEntry.make(projects: [project], sessions: [], chats: [], hasArchivedChats: true)
    #expect(archivedOnly.last?.id == SidebarEntry.chatsID)

    // Every chat, a project's or not, in the order given (the store's, newest first), with its place.
    let loose = shell("loose", project: ChatProject.standalone, created: "2026-01-01")
    let gone = shell("gone", project: "deleted", created: "2025-12-01")
    let entries = SidebarEntry.make(projects: [project], sessions: [], chats: [working, loose, gone])
    let chats = entries.filter { $0.chatID != nil }
    #expect(chats.map(\.id) == ["chat:busy", "chat:loose", "chat:gone"])
    #expect(chats.map(\.subtitle) == ["Project", "loose", "gone"], "the project's name, or the folder's")
    // A New Task chat in the folder the backend made for it names no place; one in a picked folder does.
    var scratch = shell("scratch", project: ChatProject.standalone, created: "2026-01-02")
    scratch.workingDirectory = "/Users/me/Library/Application Support/Cascade/chat/workspaces/scratch"
    #expect(scratch.inScratchFolder && !loose.inScratchFolder)
    let scratchRow = SidebarEntry.make(projects: [project], sessions: [], chats: [scratch]).first { $0.id == "chat:scratch" }
    #expect(scratchRow?.subtitle == "")
    #expect(SidebarEntry.chatPlace(scratch, projects: [:]) == "No Project", "the archived list still groups it")
    #expect(chats.first?.destination == .chat("busy"))
    if case .chat(let status) = chats.first?.role { #expect(status.working && status.cli == "claude") }
    else { Issue.record("not a chat row") }
    #expect(!entries.contains { $0.id == "label:other-chats" })
    #expect(entries.flatMap(\.children).allSatisfy { $0.chatID == nil })
}

private func workspaceSessionForChats(_ id: String) -> WorkspaceSession {
    WorkspaceSession(id: id, projectId: "p", workspace: "/tmp", worktree: "/tmp/wt/\(id)", title: id, branch: id, url: "",
                     createdAt: "2026-01-01", pinned: false)
}

/// The Chats heading's menu lists every archived chat under its place, newest archived first;
/// choosing one asks to show it. A project's menu keeps New Chat and lists none.
@MainActor @Test func archivedChatsMenuListsArchivedChatsByPlaceAndOpensOne() throws {
    _ = NSApplication.shared
    let suite = "cascade-sidebar-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let project = Project(id: "p", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
    var older = shell("older", project: "p", created: "2026-01-01", archived: true); older.archivedAt = "2026-01-02T00:00:00.000Z"
    var newer = shell("newer", project: "p", created: "2026-01-01", archived: true); newer.archivedAt = "2026-03-01T00:00:00.000Z"
    var child = shell("subagent:newer:t", project: "p", created: "2026-01-01", archived: true); child.parentThreadId = "newer"
    var loose = shell("loose", project: ChatProject.standalone, created: "2026-01-01", archived: true); loose.archivedAt = "2026-02-01T00:00:00.000Z"
    let live = shell("live", project: "p", created: "2026-02-01")
    let chats = [older, newer, child, live, loose]
    let all = SidebarArchivedChats.of(chats, projects: [project])
    #expect(all.items.map(\.id) == ["newer", "loose", "older"], "archived only, no subagent, newest archived first")
    #expect(all.items.map(\.place) == ["Project", "loose", "Project"])
    #expect(all.byPlace.map(\.place) == ["Project", "loose"])
    #expect(all.byPlace.first?.items.map(\.id) == ["newer", "older"])
    let capped = SidebarArchivedChats.of(chats, projects: [project], limit: 1)
    #expect(capped.items.map(\.id) == ["newer"] && capped.more == 2)

    var opened: [String] = []
    var value = CocoaSidebar(entries: SidebarEntry.make(projects: [project], sessions: [], chats: [live]),
                             selection: .overview, pinnedIDs: [], onSelect: { _ in }, onTogglePin: { _ in })
    value.archivedChats = { capped }
    value.onOpenArchivedChat = { opened.append($0) }
    let coordinator = CocoaSidebar.Coordinator(parent: value, preferences: preferences)
    let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
    let column = NSTableColumn(identifier: .init("name"))
    outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = coordinator; outline.delegate = coordinator
    coordinator.outline = outline
    coordinator.update(value)
    func node(_ id: String) throws -> CocoaSidebar.Node {
        try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CocoaSidebar.Node }.first { $0.entry.id == id })
    }
    let projectMenu = try #require(coordinator.menu(for: try node("project:p")))
    #expect(!projectMenu.items.contains { $0.title == "Archived Chats" }, "on the Chats heading, not a project")
    // A chat belongs to no project: a project's menu starts none.
    #expect(!projectMenu.items.contains { $0.title == "New Chat" })
    #expect(projectMenu.items.contains { $0.title == "New Task" })

    let heading = try #require(coordinator.menu(for: try node(SidebarEntry.chatsID)))
    let archived = try #require(heading.items.first { $0.title == "Archived Chats" })
    let items = try #require(archived.submenu).items
    #expect(items.map(\.title) == ["Project", "newer", "", "2 more not shown"], "\(items.map(\.title))")
    #expect(items.first?.isSectionHeader == true && items.last?.action == nil, "a place's header and the count are notes, not choices")
    _ = (items[1].target as? NSObject)?.perform(try #require(items[1].action), with: items[1])
    #expect(opened == ["newer"])

    // None archived: the item is there, greyed, with nothing under it.
    value.archivedChats = { .empty }
    coordinator.update(value)
    let none = try #require(coordinator.menu(for: try node(SidebarEntry.chatsID))?.items.first { $0.title == "Archived Chats" })
    #expect(none.submenu == nil && none.action == nil)
}

/// An archived chat chosen from the Chats menu is shown; its screen's Unarchive asks the app to list it again.
@MainActor @Test func anArchivedChatOpenedFromTheMenuRoutesToItsScreenAndUnarchives() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ChatRuntimeFixture()
    runtime.archived = ["t1"]
    coordinator.chatRuntime = runtime
    coordinator.handle(RootViewModel.Action.select(.chat("t1")))
    #expect(coordinator.selection == .chat("t1"))
    let screen = try #require(coordinator.chatCoordinator)
    #expect(screen.model.archived)
    #expect(Destination.chatCoordinator(screen).windowToolbar.trailing.map(\.id) == ["chat-unarchive", "chat-open-folder"])
    screen.model.unarchive()
    #expect(runtime.performed == [.unarchive])

    // A chat that is not archived offers no Unarchive, and asks none.
    coordinator.navigate(to: .chat("t2"))
    let other = try #require(coordinator.chatCoordinator)
    #expect(!other.model.archived && Destination.chatCoordinator(other).windowToolbar.trailing.map(\.id) == ["chat-open-folder"])
    other.model.unarchive()
    #expect(runtime.performed == [.unarchive])
}

/// The page asks for another chat (a fork it made): the window goes to it, and the app hears of it
/// first so it can read the list again. Its own chat, or no id, is no ask.
@MainActor @Test func chatPageOpenThreadShowsThatChat() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ChatRuntimeFixture()
    coordinator.chatRuntime = runtime
    coordinator.navigate(to: .chat("t1"))
    let first = try #require(coordinator.chatCoordinator)

    first.model.page.receive(message: ["kind": "event", "name": "openThread", "payload": ["threadId": "t1"]])
    first.model.page.receive(message: ["kind": "event", "name": "openThread", "payload": [:]])
    #expect(runtime.performed.isEmpty && coordinator.chatCoordinator === first)

    first.model.page.receive(message: ["kind": "event", "name": "openThread", "payload": ["threadId": "t2"]])
    #expect(runtime.performed == [.openThread("t2")])
    #expect(coordinator.selection == .chat("t2") && coordinator.chatCoordinator?.threadID == "t2")
    #expect(first.retired && first.model.page.retired)
}

// MARK: - Attachment images

private actor AttachmentReads {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

/// The page's attachment images come from `attachments.read` on its own scheme, as the type the
/// backend names; a path that is not a plain attachment id is refused without asking.
@MainActor @Test func chatSchemeServesAttachmentImagesAndRefusesOtherPaths() async throws {
    let reads = AttachmentReads()
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let assets = ChatPageAssets(readAttachment: { id in
        await reads.add(id)
        switch id {
        case "thread-1_image.png": return ["mimeType": "image/png", "dataBase64": .string(png.base64EncodedString())]
        case "notes.txt": return ["mimeType": "text/html", "dataBase64": .string(Data("<script>".utf8).base64EncodedString())]
        default: throw ChatRPCError(message: "No such attachment")
        }
    })
    func serve(_ text: String) async -> (Data, String)? { await assets.response(for: URL(string: text)!) }

    let served = try #require(await serve("cascade-chat://page/attachments/thread-1_image.png"))
    #expect(served.0 == png && served.1 == "image/png")
    // An attachment that is not an image, or one the backend does not have, is not served.
    #expect(await serve("cascade-chat://page/attachments/notes.txt") == nil)
    #expect(await serve("cascade-chat://page/attachments/missing") == nil)
    #expect(await reads.ids == ["thread-1_image.png", "notes.txt", "missing"])

    for refused in ["cascade-chat://page/other/thread-1_image.png", "cascade-chat://page/thread-1_image.png",
                    "cascade-chat://elsewhere/attachments/thread-1_image.png", "https://page/attachments/thread-1_image.png",
                    "cascade-chat://page/attachments/a/b", "cascade-chat://page/attachments/a%2Fb",
                    "cascade-chat://page/attachments/..", "cascade-chat://page/attachments/%2E%2E",
                    "cascade-chat://page/attachments/a..b", "cascade-chat://page/attachments/.hidden",
                    "cascade-chat://page/attachments/", "cascade-chat://page/attachments/a%00b"] {
        #expect(await serve(refused) == nil, "\(refused)")
    }
    #expect(await reads.ids.count == 3)
    // A page with no reader (a transcript's) serves no attachment.
    #expect(await ChatPageAssets().response(for: URL(string: "cascade-chat://page/attachments/thread-1_image.png")!) == nil)
}

/// Synara builds an attachment's image URL as `new URL("/attachments/<id>", location.origin)`
/// (`wsHttpUrl.ts`), so the page's origin on its own scheme must be a real one, not "null". This
/// loads the built page through `ChatPageAssets` in a real web view, checks the origin and that
/// resolution, and loads an image at such a URL from the scheme, past the page's CSP.
@MainActor @Test func chatPageResolvesAttachmentURLsOnItsScheme() async throws {
    ChatPageAssets.directoryOverride = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ChatPage")
    defer { ChatPageAssets.directoryOverride = nil }
    // A 1x1 PNG.
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    let reads = AttachmentReads()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(ChatPageAssets(readAttachment: { id in
        await reads.add(id)
        return ["mimeType": "image/png", "dataBase64": .string(png)]
    }), forURLScheme: ChatPageAssets.scheme)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    view.load(URLRequest(url: ChatPageAssets.pageURL))
    var state: String?
    for _ in 0..<400 {
        state = try? await view.evaluateJavaScript("location.href + ' ' + document.readyState") as? String
        if state == "\(ChatPageAssets.pageURL.absoluteString) complete" { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(state == "\(ChatPageAssets.pageURL.absoluteString) complete", "the page did not load")

    #expect(try await view.evaluateJavaScript("location.origin") as? String == "cascade-chat://page")
    let resolved = try await view.evaluateJavaScript("new URL('/attachments/x', location.origin).href") as? String
    #expect(resolved == "cascade-chat://page/attachments/x")
    let loaded = try await view.callAsyncJavaScript("""
        const image = new Image();
        image.src = new URL("/attachments/" + encodeURIComponent("thread-1_image.png"), location.origin).href;
        try { await image.decode(); } catch (error) { return "failed: " + error; }
        return image.naturalWidth + "x" + image.naturalHeight;
        """, contentWorld: .page) as? String
    #expect(loaded == "1x1")
    #expect(await reads.ids == ["thread-1_image.png"])
}

/// Every chat page shares one persistent data store, so what one page keeps in its localStorage
/// (Synara's drafts and queued follow-ups) is there for the page made when the chat comes back;
/// and a page that is retired writes what it holds back first (`nativeChat.flush`).
@MainActor @Test func chatPagesShareOnePersistentStoreAndFlushWhenRetired() async throws {
    ChatPageAssets.directoryOverride = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ChatPage")
    defer { ChatPageAssets.directoryOverride = nil }
    func loaded() async throws -> (ChatPageModel, WKWebView) {
        let page = ChatPageModel(context: pageContext(), backend: PageBackend())
        let view = try #require(page.webView)
        for _ in 0..<400 {
            if try await view.evaluateJavaScript("typeof window.nativeChat?.flush") as? String == "function" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await view.evaluateJavaScript("typeof window.nativeChat?.flush") as? String == "function", "the page did not load")
        return (page, view)
    }
    let key = "cascade-test-\(UUID().uuidString)"
    let (first, firstView) = try await loaded()
    #expect(firstView.configuration.websiteDataStore.isPersistent)
    #expect(firstView.configuration.websiteDataStore.identifier == ChatPageModel.dataStoreIdentifier)
    // The page's own localStorage, not the in-memory stand-in storage.ts puts in when there is none.
    _ = try await firstView.evaluateJavaScript("localStorage.setItem('\(key)', 'kept'); 0")
    // What the page writes when it is told it is closing.
    _ = try await firstView.evaluateJavaScript("window.addEventListener('pagehide', () => localStorage.setItem('\(key)-flushed', 'yes')); 0")
    first.retire()

    let (second, secondView) = try await loaded()
    defer { second.retire() }
    #expect(secondView.configuration.websiteDataStore === firstView.configuration.websiteDataStore)
    #expect(try await secondView.evaluateJavaScript("localStorage.getItem('\(key)') ?? ''") as? String == "kept")
    var flushed: String?
    for _ in 0..<80 {
        flushed = try await secondView.evaluateJavaScript("localStorage.getItem('\(key)-flushed') ?? ''") as? String
        if flushed == "yes" { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(flushed == "yes", "the retired page did not flush")
    _ = try await secondView.evaluateJavaScript("localStorage.removeItem('\(key)'); localStorage.removeItem('\(key)-flushed'); 0")
}

// MARK: - Sidebar row layout

/// A chat row's title has the row first: the subtitle takes only what the title leaves, truncating,
/// and is dropped before the title is cut.
@MainActor @Test func aChatRowsTitleWinsOverItsSubtitle() {
    let layout = SidebarCellView.titleAndSubtitle
    let gap = SidebarCellView.subtitleGap
    // Room for both: each at its own width.
    #expect(layout(200, 80, 60) == (80, 60))
    // Room for the title and part of the subtitle: the subtitle truncates, the title stays whole.
    #expect(layout(150, 80, 100) == (80, 150 - 80 - gap))
    // Too little left for a subtitle worth reading: it goes, and the title keeps its full width.
    #expect(layout(100, 80, 100) == (80, 0))
    // A title wider than the row is cut only to the row, with nothing left for the subtitle.
    #expect(layout(120, 300, 50) == (120, 0))
    #expect(layout(0, 80, 50) == (0, 0))
    // A subtitle shorter than the minimum shows whole when it fits.
    #expect(layout(110, 80, 20) == (80, 20))
}
