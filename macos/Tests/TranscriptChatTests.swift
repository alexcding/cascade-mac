import Foundation
import Testing

/// What the chat hands the terminal and its hooks, recorded.
@MainActor private final class ChatFixture {
    var typed: [String] = []
    /// The files pasted ahead of each typed message.
    var pasted: [[String]] = []
    var transcript = AgentTranscript(revision: "r0", turns: [], hooks: "installed")
    var runID: String? = "run-a"
    var watched: [String] = []
    var unwatched: [String] = []
    var answers: [(String, String)] = []
    var terminalShown = 0
    var watcher: PermissionWatcher?

    /// Held strongly by what it builds: a send can finish after the test that started it.
    func model() -> TranscriptChatModel {
        TranscriptChatModel(
            agentName: "Claude",
            load: { _ in self.transcript },
            deliver: { text, files in
                self.pasted.append(files.map(\.path))
                self.typed.append(text)
            },
            permissions: .init(
                runID: { self.runID },
                watch: { run, watcher in self.watched.append(run); self.watcher = watcher },
                unwatch: { run in self.unwatched.append(run) },
                answer: { id, decision in self.answers.append((id, decision)) }),
            showTerminal: { self.terminalShown += 1 })
    }
}

private func prompt(_ id: String, at date: Date) -> TranscriptTurn {
    TranscriptTurn(id: id, role: .user, timestamp: ISO8601DateFormatter().string(from: date), ended: nil, model: nil,
                   blocks: [TranscriptBlock(type: .text, text: id, id: nil, name: nil, summary: nil, command: nil,
                                            path: nil, old: nil, new: nil, output: nil, isError: nil)])
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
    #expect(condition())
}

@MainActor @Test func aMessageSentWhileTheAgentWorksWaitsForItsPrompt() async {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "and the tests"
    await chat.send()
    // A dialog may be up in the terminal the chat covers: nothing is typed into it.
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "and the tests" && chat.draft.isEmpty && !chat.canSend)
    chat.setAgentState(busy: false, idle: true)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.typed == ["and the tests"] && chat.queuedPrompt == nil && chat.pendingPrompt == "and the tests")
}

@MainActor @Test func aHeldMessageGoesOnlyWhenAskedAndComesBackWhenCancelled() async {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.draft = "first"
    await chat.send()
    #expect(fixture.typed.isEmpty, "Never heard at its prompt, the agent is not typed into")
    await chat.sendQueuedNow()
    #expect(fixture.typed == ["first"])
    chat.draft = "second"
    await chat.send()
    chat.cancelQueued()
    #expect(chat.queuedPrompt == nil && chat.draft == "second" && fixture.typed == ["first"])
}

@MainActor @Test func theSentBubbleClearsOnAPromptWrittenAfterItNotOnTheCount() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let old = Date().addingTimeInterval(-600)
    fixture.transcript = AgentTranscript(revision: "r1", turns: [prompt("a", at: old), prompt("b", at: old)], hooks: "installed")
    await chat.refresh()
    chat.setAgentState(busy: false, idle: true)
    chat.draft = "c"
    await chat.send()
    #expect(chat.pendingPrompt == "c")
    // The window moved: an old prompt fell off the front and a new one came in, so the count held.
    fixture.transcript = AgentTranscript(revision: "r2", turns: [prompt("b", at: old), prompt("c", at: Date())], hooks: "installed")
    await chat.refresh()
    #expect(chat.pendingPrompt == nil)
}

@MainActor @Test func aSentBubbleStaysWhileOnlyOlderPromptsAreRead() async {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.setAgentState(busy: false, idle: true)
    chat.draft = "c"
    await chat.send()
    fixture.transcript = AgentTranscript(revision: "r1", turns: [prompt("a", at: Date().addingTimeInterval(-600))], hooks: "installed")
    await chat.refresh()
    #expect(chat.pendingPrompt == "c")
}

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

@MainActor @Test func anInterruptTheHooksMissedStillLetsAHeldMessageGo() async {
    let fixture = ChatFixture(), chat = fixture.model()
    // The turn started, and Claude sends no Stop for an interrupt: the hooks still say busy.
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "try it another way"
    await chat.send()
    #expect(fixture.typed.isEmpty)
    try? await Task.sleep(for: .milliseconds(20))
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(Date()))
    await chat.refresh()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.typed == ["try it another way"] && chat.atPrompt == false, "Typing it starts work again")
}

@MainActor @Test func aFreshCodexSessionTakesAMessageAtOnce() async {
    let fixture = ChatFixture(), chat = fixture.model()
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(Date().addingTimeInterval(-30)))
    await chat.refresh()
    chat.draft = "hello"
    await chat.send()
    #expect(fixture.typed == ["hello"])
}

@MainActor @Test func aPromptMarkerOlderThanTheTurnHoldsNothingBack() async {
    let fixture = ChatFixture(), chat = fixture.model()
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(Date().addingTimeInterval(-30)))
    await chat.refresh()
    // A turn began after the marker was written; the transcript has not caught up.
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "wait for it"
    await chat.send()
    fixture.transcript = AgentTranscript(revision: "r2", turns: [], hooks: "installed", atPrompt: stamp(Date().addingTimeInterval(-30)))
    await chat.refresh()
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "wait for it")
}

@MainActor @Test func theHookInstallDecidesWhatTheChatOwnsUpTo() async {
    let fixture = ChatFixture(), chat = fixture.model()
    await chat.refresh()
    #expect(chat.hookNotice == nil)
    fixture.transcript = AgentTranscript(revision: "r0", turns: nil, hooks: "outdated")
    await chat.refresh()
    #expect(chat.hookNotice?.contains("terminal") == true)
    fixture.transcript = AgentTranscript(revision: "r0", turns: nil, hooks: "absent")
    await chat.refresh()
    #expect(chat.hookNotice?.contains("Send Now") == true)
}

@MainActor @Test func approvalsFollowARestartedTerminalAndATerminalFallbackShowsIt() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.appear()
    defer { chat.retire() }
    try await eventually { fixture.watched == ["run-a"] }
    let details = AgentPermissionPrompt.Details(tool: "Bash", detail: "rm -rf build", reason: "")
    fixture.watcher?.show(AgentPermissionPrompt(id: "p1", details: details))
    #expect(chat.permission?.id == "p1" && !chat.canSendQueuedNow)
    // A restart gives the terminal a new run id; its approvals must still reach the chat.
    fixture.runID = "run-b"
    try await eventually { fixture.watched == ["run-a", "run-b"] }
    #expect(fixture.unwatched == ["run-a"] && chat.permission == nil)
    fixture.watcher?.movedToTerminal()
    #expect(fixture.terminalShown == 1)
}

@MainActor @Test func handingARequestToTheTerminalShowsTheTerminal() async {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.appear()
    defer { chat.retire() }
    try? await eventually { fixture.watcher != nil }
    fixture.watcher?.show(AgentPermissionPrompt(id: "p1", details: .init(tool: "Bash", detail: "x", reason: "", truncated: true)))
    await chat.answerPermission("p1", decision: "pass")
    #expect(fixture.answers.map(\.1) == ["pass"] && fixture.terminalShown == 1)
    await chat.answerPermission("p1", decision: "allow")
    #expect(fixture.answers.count == 1, "An answered request is not answered again")
}

@MainActor @Test func aRetiredChatRefusesEverything() async {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.retire()
    chat.draft = "late"
    await chat.send()
    chat.appear()
    chat.setAgentState(busy: false, idle: true)
    await chat.refresh()
    #expect(fixture.typed.isEmpty && fixture.watched.isEmpty && chat.page == nil && !chat.loaded)
}

@Test func downloadsAreNumberedNotOverwrittenAndMarkedAsDownloaded() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-downloads-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try #require(TranscriptChatPage.saveToDownloads(Data("a".utf8), named: "table.csv", in: folder))
    let second = try #require(TranscriptChatPage.saveToDownloads(Data("b".utf8), named: "table.csv", in: folder))
    let odd = try #require(TranscriptChatPage.saveToDownloads(Data("c".utf8), named: "../..hidden/x:y", in: folder))
    #expect(first.lastPathComponent == "table.csv" && second.lastPathComponent == "table 2.csv")
    #expect(odd.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL && !odd.lastPathComponent.hasPrefix("."))
    #expect(try String(contentsOf: first, encoding: .utf8) == "a")
    let quarantine = try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
    #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Cascade")
}

@MainActor @Test func aJustStartedAgentKeepsItsTerminalInViewUntilItIsAtItsPrompt() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let started = Date()
    // Resumed into its old conversation: the transcript's last turn end is from before this start,
    // and the agent may be asking to trust its hooks in the terminal right now.
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(started.addingTimeInterval(-60)))
    chat.setAgentState(busy: false, idle: false, startedAt: started)
    await chat.refresh()
    #expect(!chat.coversTerminal && !chat.atPrompt)
    chat.draft = "hello"
    await chat.send()
    #expect(fixture.typed.isEmpty, "Nothing is typed into a question the chat would hide")
    fixture.transcript = AgentTranscript(revision: "r2", turns: [], hooks: "installed", atPrompt: stamp(started.addingTimeInterval(1)))
    await chat.refresh()
    #expect(chat.coversTerminal)
    try? await eventually { fixture.typed == ["hello"] }
}

@MainActor @Test func aTurnTheHooksHearOrOpenChatShowsTheChat() {
    let fixture = ChatFixture(), chat = fixture.model()
    let started = Date()
    chat.setAgentState(busy: false, idle: false, startedAt: started)
    #expect(!chat.coversTerminal)
    chat.setAgentState(busy: true, idle: false, startedAt: started)
    #expect(chat.coversTerminal, "A turn started, so the agent got past its questions")
    let other = fixture.model()
    other.setAgentState(busy: false, idle: false, startedAt: Date())
    other.openChat()
    #expect(other.coversTerminal)
}

@MainActor @Test func aShellThatWasAlreadyRunningShowsTheChatAtOnce() {
    let chat = ChatFixture().model()
    chat.setAgentState(busy: false, idle: false, startedAt: nil)
    #expect(chat.coversTerminal)
}

@MainActor @Test func filesGoWithTheMessageAndComeBackWithItWhenCancelled() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let shot = ChatAttachment(path: "/tmp/image.png", name: "image.png")
    chat.attach([shot, shot])
    #expect(chat.attachments.count == 1, "The same file is attached once")
    #expect(chat.canSend, "Files alone are a message")
    await chat.send()
    #expect(chat.attachments.isEmpty && chat.queuedAttachments == [shot] && !chat.canAttach)
    chat.cancelQueued()
    #expect(chat.attachments == [shot] && chat.queuedAttachments.isEmpty && fixture.typed.isEmpty)
    chat.draft = "what is this"
    await chat.send()
    await chat.sendQueuedNow()
    #expect(fixture.pasted == [["/tmp/image.png"]] && fixture.typed == ["what is this"])
    #expect(chat.pendingPrompt == "image.png\n\nwhat is this" && chat.queuedAttachments.isEmpty)
}

@MainActor @Test func aRemovedFileIsNotPasted() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let kept = ChatAttachment(path: "/tmp/a.txt", name: "a.txt"), dropped = ChatAttachment(path: "/tmp/b.txt", name: "b.txt")
    chat.attach([kept, dropped])
    chat.removeAttachment(dropped.id)
    chat.draft = "read it"
    await chat.send()
    await chat.sendQueuedNow()
    #expect(fixture.pasted == [["/tmp/a.txt"]])
}

@MainActor @Test func aMessageWaitsForAFileStillBeingStaged() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let shot = ChatAttachment(path: "/tmp/shot.png", name: "shot.png")
    var finish: CheckedContinuation<Void, Never>?
    chat.draft = "look"
    chat.attach {
        await withCheckedContinuation { finish = $0 }
        return [shot]
    }
    #expect(chat.staging == 1 && !chat.canSend, "Send waits for the screenshot")
    while finish == nil { await Task.yield() }
    finish?.resume()
    while chat.staging > 0 { await Task.yield() }
    #expect(chat.attachments == [shot] && chat.canSend)
}

@Test func aPasteOfEscapedPathsSplitsIntoItsFiles() {
    let files = ChatAttachmentReader.files(pasted: "/tmp/My\\ Shot.png /tmp/b\\(1\\).txt")
    #expect(files.map(\.path) == ["/tmp/My\\ Shot.png", "/tmp/b\\(1\\).txt"])
    #expect(files.map(\.name) == ["My Shot.png", "b(1).txt"])
    #expect(ChatAttachmentReader.files([URL(fileURLWithPath: "/tmp/My Shot.png")]).map(\.path) == ["/tmp/My\\ Shot.png"])
}
