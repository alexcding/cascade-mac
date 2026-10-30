import Foundation
import Testing

// MARK: - Fixtures

/// This Mac's remote routes, answered from what the test sets; every call is kept.
private final class FakeRemote: RemoteServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = RemoteStatus(enabled: true, port: 52000, fingerprint: "self")
    private var _peers: [RemotePeer] = []
    private var _sessions: [String: [WorkspaceSession]] = [:]
    private var _chats: [String: [JSONValue]] = [:]
    private var _calls: [String] = []
    private var _paired: RemotePeer?

    var calls: [String] { lock.withLock { _calls } }
    func set(peers: [RemotePeer]) { lock.withLock { _peers = peers } }
    func set(sessions: [WorkspaceSession], chats: [JSONValue], for peer: String) {
        lock.withLock { _sessions[peer] = sessions; _chats[peer] = chats }
    }
    func pairs(as peer: RemotePeer) { lock.withLock { _paired = peer } }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    func status() async throws -> RemoteStatus { log("status"); return lock.withLock { _status } }
    func setEnabled(_ enabled: Bool) async throws -> RemoteStatus {
        log("enabled \(enabled)")
        return lock.withLock { _status.enabled = enabled; return _status }
    }
    func clients() async throws -> [RemoteClient] { [] }
    func revoke(client id: String) async throws { log("revoke \(id)") }
    func openPairing(name: String?) async throws -> RemotePairingCode { log("open"); return RemotePairingCode(code: "123456", seconds: 300) }
    func pairingWindow() async throws -> RemotePairingWindow { RemotePairingWindow(open: false, attemptsLeft: 3, seconds: 0) }
    func closePairing() async throws { log("close") }
    func peers() async throws -> [RemotePeer] { log("peers"); return lock.withLock { _peers } }
    func pair(address: String, code: String, label: String?) async throws -> RemotePeer {
        log("pair \(address) \(code)")
        guard let peer = lock.withLock({ _paired }) else { throw BackendError.operation("wrong code") }
        return peer
    }
    func forget(peer id: String) async throws { log("forget \(id)") }
    func connect(peer id: String, address: String?) async throws { log("connect \(id) \(address ?? "-")") }
    func sessions(peer id: String) async throws -> [WorkspaceSession] {
        log("sessions \(id)")
        return lock.withLock { _sessions[id] ?? [] }
    }
    func chat(peer id: String) -> any ChatServing {
        RemoteChat { [weak self] method in
            guard let self else { return .null }
            log("chat \(id) \(method)")
            return method == "chat.listThreads" ? .array(lock.withLock { _chats[id] ?? [] }) : .null
        }
    }
}

private struct RemoteChat: ChatServing {
    let answer: @Sendable (String) async throws -> JSONValue
    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue { try await answer(method) }
}

private func session(_ id: String, title: String) -> WorkspaceSession {
    WorkspaceSession(id: id, projectId: "p", workspace: "/Users/other/repo", worktree: "/Users/other/repo-\(id)",
                     title: title, branch: "b", url: "", createdAt: nil, pinned: false)
}

private func shell(_ id: String, title: String, subagentOf parent: String? = nil, worktree: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["id": .string(id), "projectId": "p", "title": .string(title),
                                       "createdAt": .string("2026-10-0\(id.count)T00:00:00.000Z")]
    if let parent { object["parentThreadId"] = .string(parent) }
    if let worktree { object["worktreePath"] = .string(worktree) }
    return .object(object)
}

private func event(_ json: String) throws -> ServerEvent {
    try JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8))
}

// MARK: - Events

@Test func remoteEventsDecodeWithTheirRelayedEvent() throws {
    let relayed = try event(#"{"type":"remote","peer":"ab","relayed":{"type":"chat-removed","threadId":"t1"}}"#)
    #expect(relayed.peer == "ab" && relayed.relayed?["threadId"]?.string == "t1")
    let reach = try event(#"{"type":"remote-peer","peer":"ab","reach":"online"}"#)
    #expect(reach.reach == "online")
}

@Test func aPeerInAStateThisBuildDoesNotKnowReadsAsOffline() throws {
    let peer = try JSONDecoder().decode(RemotePeer.self, from: Data(#"{"id":"ab","name":"Mac mini","addresses":[],"reach":"asleep"}"#.utf8))
    #expect(peer.reach == .offline)
}

// MARK: - Bonjour

@Test func aSightingNeedsAnIdAHostAndAPort() {
    #expect(RemoteBonjour.sighting(["id": "ab", "name": "Mac mini", "host": "mini.local", "port": "52000"])
        == .init(id: "ab", name: "Mac mini", address: "mini.local:52000"))
    #expect(RemoteBonjour.sighting(["id": "ab", "host": "mini.local", "port": "52000"])?.name == "mini.local")
    #expect(RemoteBonjour.sighting(["host": "mini.local", "port": "52000"]) == nil)
    #expect(RemoteBonjour.sighting(["id": "ab", "host": "mini.local", "port": "0"]) == nil)
    #expect(RemoteBonjour.sighting(["id": "ab", "port": "52000"]) == nil)
}

@Test func aTXTRecordIsEachEntrysLengthThenItsText() {
    let record = RemoteBonjour.txtRecord([("id", "ab"), ("port", "1")])
    #expect(Array(record) == [5] + Array("id=ab".utf8) + [6] + Array("port=1".utf8))
}

// MARK: - Sidebar

@MainActor @Test func aPairedMacHasASectionOfItsOwnAfterThisMacs() throws {
    let peer = RemotePeer(id: "ab", name: "Mac mini", reach: .online)
    let chat = try shell("t1", title: "Fix it").decode(ChatThreadShell.self)
    let entries = SidebarEntry.make(projects: [], sessions: [], remote: [
        SidebarRemoteSection(peer: peer, sessions: [session("s1", title: "Build")], chats: [chat])
    ])
    let tail = entries.suffix(3)
    #expect(tail.map(\.id) == ["label:remote:ab", "remote-session:ab:s1", "remote-chat:ab:t1"])
    #expect(tail.map(\.title) == ["Mac mini", "repo-s1", "Fix it"], "a session by its label, as this Mac's are")
    // A session runs on the other Mac: listed, not opened. A chat opens read-only.
    #expect(tail.map(\.destination) == [nil, nil, .remoteChat(peer: "ab", thread: "t1")])
    // Nothing names a path of this Mac's, so nothing offers Finder.
    #expect(tail.allSatisfy { $0.detail.isEmpty })

    let offline = SidebarEntry.make(projects: [], sessions: [], remote: [SidebarRemoteSection(peer: RemotePeer(id: "ab", name: "Mac mini"))])
    #expect(offline.last?.title == "Mac mini · Offline")
}

// MARK: - The paired Macs' lists

@MainActor @Test func theStoreReadsEachMacThatAnswersAndFollowsItsEvents() async throws {
    let remote = FakeRemote()
    remote.set(peers: [RemotePeer(id: "ab", name: "Mac mini", reach: .online), RemotePeer(id: "cd", name: "Studio")])
    remote.set(sessions: [session("s1", title: "Build")],
               chats: [shell("t1", title: "One"), shell("t22", title: "Sub", subagentOf: "t1"), shell("t333", title: "Pane", worktree: "/w")],
               for: "ab")
    let store = RemotePeersStore()
    store.connect(remote)
    await store.settle()

    #expect(store.peers.map(\.id) == ["ab", "cd"])
    #expect(store.sessions["ab"]?.map(\.id) == ["s1"])
    // A subagent's thread and a pane's chat are not listed, as for this Mac's chats.
    #expect(store.visibleChats("ab").map(\.id) == ["t1"])
    // A Mac not answering is not read.
    #expect(!remote.calls.contains("sessions cd"))

    // It comes online: read.
    remote.set(sessions: [session("s2", title: "Test")], chats: [], for: "cd")
    store.receive(try event(#"{"type":"remote-peer","peer":"cd","reach":"online"}"#))
    await store.settle()
    #expect(store.peer("cd")?.reach == .online && store.sessions["cd"]?.map(\.id) == ["s2"])

    // What a Mac relays: a chat's shell is kept as it came, a removal removes it.
    store.receive(try event(#"{"type":"remote","peer":"ab","relayed":{"type":"chat-shell","shell":{"id":"t4","projectId":"p","title":"Four","createdAt":"2026-10-09T00:00:00.000Z"}}}"#))
    #expect(store.visibleChats("ab").map(\.id) == ["t4", "t1"])
    store.receive(try event(#"{"type":"remote","peer":"ab","relayed":{"type":"chat-removed","threadId":"t1"}}"#))
    #expect(store.visibleChats("ab").map(\.id) == ["t4"])

    // Its sessions changed: read again.
    let before = remote.calls.filter { $0 == "sessions ab" }.count
    store.receive(try event(#"{"type":"remote","peer":"ab","relayed":{"type":"tasks"}}"#))
    await store.settle()
    #expect(remote.calls.filter { $0 == "sessions ab" }.count == before + 1)

    // A Mac forgotten goes with its lists.
    remote.set(peers: [RemotePeer(id: "ab", name: "Mac mini", reach: .online)])
    store.receive(try event(#"{"type":"remote-peers"}"#))
    await store.settle()
    #expect(store.peers.map(\.id) == ["ab"] && store.sessions["cd"] == nil)

    // Events of another kind are not the store's.
    #expect(!store.receive(try event(#"{"type":"tasks"}"#)))
    store.connect(nil)
    #expect(store.peers.isEmpty && store.sessions.isEmpty)
}

// MARK: - Settings → Remote

@MainActor @Test func settingsLooksForMacsNotAnsweringOnlyWhileItShows() async throws {
    let remote = FakeRemote()
    remote.set(peers: [RemotePeer(id: "ab", name: "Mac mini"), RemotePeer(id: "cd", name: "Studio", reach: .online)])
    let model = RemoteSettingsViewModel(makeBrowser: { nil }, makeAdvertiser: { _, _, _ in nil }, name: { "This Mac" })
    model.connect(remote)
    #expect(remote.calls.isEmpty, "nothing is read before the section shows")

    model.setActive(true)
    try await waitUntil { remote.calls.contains("connect ab -") }
    // Only the Mac not answering, once.
    #expect(!remote.calls.contains { $0.hasPrefix("connect cd") })

    // Bonjour sees it at an address: tried there. It sees this Mac and an unpaired one too.
    model.seen([.init(id: "ab", name: "Mac mini", address: "mini.local:1"), .init(id: "self", name: "Me", address: "me.local:2"),
                .init(id: "ef", name: "Laptop", address: "laptop.local:3")])
    try await waitUntil { remote.calls.contains("connect ab mini.local:1") }
    #expect(model.nearby.map(\.id) == ["ef"])
    model.seen([.init(id: "ab", name: "Mac mini", address: "mini.local:1")])
    try await Task.sleep(for: .milliseconds(50))
    #expect(remote.calls.filter { $0 == "connect ab mini.local:1" }.count == 1, "the same sighting is not tried again")

    // Hidden: Bonjour stops, and a sighting does nothing.
    model.setActive(false)
    let calls = remote.calls.count
    model.seen([.init(id: "ab", name: "Mac mini", address: "other.local:1")])
    try await Task.sleep(for: .milliseconds(50))
    #expect(remote.calls.count == calls && model.nearby.isEmpty)
}

@MainActor @Test func settingsPairsWithACodeAndShowsWhyItFailed() async throws {
    let remote = FakeRemote()
    let model = RemoteSettingsViewModel(makeBrowser: { nil }, makeAdvertiser: { _, _, _ in nil }, name: { "This Mac" })
    model.connect(remote)
    #expect(await model.pair(address: "mini.local:1", code: "12345") == false, "a code is six digits")
    #expect(await model.pair(address: "mini.local:1", code: "123 456") == false)
    #expect(model.pairError == "wrong code")

    remote.pairs(as: RemotePeer(id: "ab", name: "Mac mini", reach: .connecting))
    #expect(await model.pair(address: "mini.local:1", code: "123456"))
    #expect(model.peers.map(\.id) == ["ab"] && model.pairError == nil)

    await model.openPairing()
    #expect(model.pairingCode == "123456" && model.pairingCloses != nil)
    await model.closePairing()
    #expect(model.pairingCode == nil && remote.calls.contains("close"))
}

@MainActor private func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

// MARK: - The chat screen

@MainActor private final class RemoteChatRuntime: ChatCoordinating {
    var made: [String] = []
    var performed: [ChatViewModel.Action] = []
    func makeChatModel(threadID: String) -> ChatViewModel? { nil }
    func performChatAction(_ action: ChatViewModel.Action, threadID: String) {}
    func makeRemoteChatModel(peer: String, threadID: String) -> ChatViewModel? {
        made.append("\(peer)/\(threadID)")
        let context = ChatPageContext(threadId: threadID, projectId: "p", cwd: "", projectName: "Mac mini", readOnly: true, homeDir: nil)
        return ChatViewModel(threadID: threadID, shell: nil, projectName: "Mac mini",
                             page: ChatPageModel(context: context, backend: ChatServiceBackend(service: { nil }), output: { _ in }))
    }
    func performRemoteChatAction(_ action: ChatViewModel.Action, peer: String) { performed.append(action) }
}

@MainActor @Test func aRemoteChatIsAScreenOfItsOwnAndGoesWithItsMac() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = RemoteChatRuntime()
    coordinator.chatRuntime = runtime

    coordinator.navigate(to: .remoteChat(peer: "ab", thread: "t1"))
    guard case .chatCoordinator(let screen) = coordinator.root else { Issue.record("no chat screen: \(coordinator.root)"); return }
    #expect(screen.destination == .remoteChat(peer: "ab", thread: "t1") && runtime.made == ["ab/t1"])
    #expect(screen.canPresent())

    // The same thread id on this Mac is another chat.
    coordinator.refreshRoot()
    #expect(coordinator.chatCoordinator === screen)

    // What its page asks for goes to the remote handler, not this Mac's.
    screen.model.page.receive(message: ["kind": "event", "name": "openSettings", "payload": [:]])
    #expect(runtime.performed == [.openSettings])

    // Its Mac forgotten: the screen goes, and the window with it.
    coordinator.remoteChatRemoved(peer: "ab", thread: nil)
    #expect(screen.retired && coordinator.selection == .overview)
}
