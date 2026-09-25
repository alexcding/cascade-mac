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
    /// What the CLI and the worktree offer the suggestion list.
    var commands: [AgentCommand] = []
    var files: [String] = []
    var fileQueries: [String] = []

    /// Held strongly by what it builds: a send can finish after the test that started it.
    func model() -> TranscriptChatModel {
        TranscriptChatModel(
            agentName: "Claude",
            load: { _ in self.transcript },
            deliver: { text, files in
                self.pasted.append(files.map(\.path))
                self.typed.append(text)
            },
            completions: .init(
                commands: { self.commands },
                files: { query in self.fileQueries.append(query); return self.files }),
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

@MainActor @Test func anInterruptTheHooksMissedStillLetsAHeldMessageGo() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    // The turn started, and Claude sends no Stop for an interrupt: the hooks still say busy.
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "try it another way"
    await chat.send()
    #expect(fixture.typed.isEmpty)
    try? await Task.sleep(for: .milliseconds(20))
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(Date()))
    await chat.refresh()
    try await eventually { fixture.typed == ["try it another way"] && !chat.atPrompt }
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
    #expect(chat.draft == String(ChatCompletion.fileMark), "Its chip is back in the field")
    chat.draft += "what is this"
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
    #expect(chat.draft == String(ChatCompletion.fileMark), "Its chip goes with it")
    chat.draft += "read it"
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

@MainActor @Test func deletingAFilesChipTakesTheFileOutOfTheMessage() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let a = ChatAttachment(path: "/tmp/a.png", name: "a.png"), b = ChatAttachment(path: "/tmp/b.png", name: "b.png")
    chat.attach([a, b])
    let mark = String(ChatCompletion.fileMark)
    // Backspace over the first chip, as the field reports it.
    chat.edit(mark + "compare", files: [b], caret: 1)
    #expect(chat.attachments == [b])
    // Select All then Delete, with nothing reported but the text.
    chat.draft = ""
    #expect(chat.attachments.isEmpty && !chat.canSend)
}

@MainActor @Test func filesArePlacedAtTheCaret() {
    let chat = ChatFixture().model()
    chat.edit("before after", files: [], caret: 7)
    let shot = ChatAttachment(path: "/tmp/shot.png", name: "shot.png")
    chat.attach([shot])
    #expect(chat.draft == "before \u{FFFC}after" && chat.caret == 8 && chat.attachments == [shot])
    #expect(ChatCompletion.text(of: chat.draft) == "before after", "The terminal gets the text without the chip")
}

@Test func theWordAtTheCaretIsACommandOnlyWhereItOpensTheMessage() {
    #expect(ChatCompletion.word(in: "/rev", caret: 4) == ChatCompletion.Word(kind: .command, query: "rev", range: NSRange(location: 0, length: 4)))
    #expect(ChatCompletion.word(in: "  /re", caret: 5)?.kind == .command)
    #expect(ChatCompletion.word(in: "hi /re", caret: 6) == nil, "A command anywhere else is text to the CLI")
    #expect(ChatCompletion.word(in: "/usr/bin", caret: 8) == nil, "A path is not a command")
    #expect(ChatCompletion.word(in: "\u{FFFC}/re", caret: 4) == nil, "Files go ahead of the text, so a command after one is text")
    #expect(ChatCompletion.word(in: "/review ", caret: 8) == nil, "A space ends the word")
}

@Test func theWordAtTheCaretIsAFileAfterAnAt() {
    #expect(ChatCompletion.word(in: "see @src/ma", caret: 11) == ChatCompletion.Word(kind: .file, query: "src/ma", range: NSRange(location: 4, length: 7)))
    // The caret mid-word completes what is before it and replaces the whole word.
    #expect(ChatCompletion.word(in: "@main x", caret: 3) == ChatCompletion.Word(kind: .file, query: "ma", range: NSRange(location: 0, length: 5)))
    #expect(ChatCompletion.word(in: "mail me@host", caret: 12) == nil, "An @ inside a word is not a mention")
}

private func command(_ name: String, _ description: String = "", hint: String = "", source: String = "builtin",
                     interactive: Bool = false) -> AgentCommand {
    AgentCommand(name: name, description: description, hint: hint, source: source, plugin: nil, interactive: interactive)
}

@Test func commandsRankByNameThenByPartThenByDescription() {
    let all = [command("preview"), command("pr-review"), command("tidy", "Review the diff"), command("review"), command("clear")]
    #expect(ChatCompletion.commands(all, matching: "rev").map(\.name) == ["review", "pr-review", "preview", "tidy"])
    #expect(ChatCompletion.commands(all, matching: "").count == all.count)
}

@MainActor @Test func aSlashListsTheCLIsCommandsAndTabCompletesOne() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("compact"), command("commit", "Commit the work", source: "project"), command("clear")]
    let chat = fixture.model()
    chat.edit("/co", files: [], caret: 3)
    try await eventually { chat.suggestions.count == 2 }
    #expect(chat.suggestions.map(\.title) == ["/compact", "/commit"])
    #expect(chat.suggestions[1].badge == "Project")
    chat.moveHighlight(1)
    await chat.acceptSuggestion()
    #expect(chat.draft == "/commit " && chat.caret == 8 && chat.suggestions.isEmpty)
    #expect(fixture.typed.isEmpty, "Completing is not sending")
}

@MainActor @Test func returnOnACommandWithoutArgumentsRunsIt() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("compact"), command("add-dir", hint: "<path>")]
    let chat = fixture.model()
    chat.setAgentState(busy: false, idle: true)
    chat.edit("/ad", files: [], caret: 3)
    try await eventually { chat.suggestions.count == 1 }
    await chat.acceptSuggestion(run: true)
    #expect(chat.draft == "/add-dir " && fixture.typed.isEmpty, "One that takes arguments waits for them")
    chat.edit("/comp", files: [], caret: 5)
    try await eventually { chat.suggestions.count == 1 }
    await chat.acceptSuggestion(run: true)
    #expect(fixture.typed == ["/compact"] && chat.draft.isEmpty)
}

@MainActor @Test func aCommandThatOpensAPanelShowsTheTerminal() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("model", hint: "[model]", interactive: true)]
    let chat = fixture.model()
    chat.setAgentState(busy: false, idle: true)
    chat.edit("/mo", files: [], caret: 3)
    try await eventually { !chat.suggestions.isEmpty }
    await chat.acceptSuggestion()
    await chat.send()
    #expect(fixture.typed == ["/model"] && fixture.terminalShown == 1)
    chat.edit("/model opus", files: [], caret: 11)
    await chat.send()
    #expect(fixture.terminalShown == 1, "With an argument it answers in the conversation")
}

@MainActor @Test func escapeClosesTheListForThatWordOnly() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("compact")]
    let chat = fixture.model()
    chat.edit("/c", files: [], caret: 2)
    try await eventually { !chat.suggestions.isEmpty }
    chat.dismissSuggestions()
    chat.edit("/co", files: [], caret: 3)
    #expect(chat.suggestions.isEmpty, "Still closed while the same word is typed")
    chat.edit("", files: [], caret: 0)
    chat.edit("/c", files: [], caret: 2)
    #expect(!chat.suggestions.isEmpty, "A new word opens it again")
}

@MainActor @Test func anAtListsWorktreeFilesAndTakesOne() async throws {
    let fixture = ChatFixture()
    fixture.files = ["src/main.rs", "src/lib.rs"]
    let chat = fixture.model()
    chat.edit("see @ma", files: [], caret: 7)
    try await eventually { chat.suggestions.count == 2 }
    #expect(fixture.fileQueries.last == "ma" && chat.suggestions[0].title == "@src/main.rs")
    await chat.acceptSuggestion()
    #expect(chat.draft == "see @src/main.rs " && chat.suggestions.isEmpty)
}

@Test func aMessageEndsInAMentionEvenWhenItsPathHasSpaces() {
    #expect(ChatCompletion.endsInMention("read @docs/Release\\ Notes.md"))
    #expect(ChatCompletion.endsInMention("@src/main.rs"))
    #expect(!ChatCompletion.endsInMention("read @src/main.rs please"))
    #expect(!ChatCompletion.endsInMention("mail me@host"))
}

@MainActor @Test func aCommandWithAFileDoesNotShowTheTerminal() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("model", hint: "[model]", interactive: true)]
    let chat = fixture.model()
    chat.setAgentState(busy: false, idle: true)
    chat.edit("/mo", files: [], caret: 3)
    try await eventually { !chat.suggestions.isEmpty }
    await chat.acceptSuggestion()
    chat.attach([ChatAttachment(path: "/tmp/a.png", name: "a.png")])
    await chat.send()
    #expect(fixture.typed == ["/model"] && fixture.pasted == [["/tmp/a.png"]] && fixture.terminalShown == 0)
}

@Test func aPasteOfEscapedPathsSplitsIntoItsFiles() {
    let files = ChatAttachmentReader.files(pasted: "/tmp/My\\ Shot.png /tmp/b\\(1\\).txt")
    #expect(files.map(\.path) == ["/tmp/My\\ Shot.png", "/tmp/b\\(1\\).txt"])
    #expect(files.map(\.name) == ["My Shot.png", "b(1).txt"])
    #expect(ChatAttachmentReader.files([URL(fileURLWithPath: "/tmp/My Shot.png")]).map(\.path) == ["/tmp/My\\ Shot.png"])
}

@MainActor @Test func chatPageEncodesLocalizedChromeWithoutChangingTranscriptContent() throws {
    let userText = "Allow /review @src/main.swift — مرحبًا <script>literal text</script>"
    var state = ChatPageState(turns: [prompt(userText, at: .distantPast)], busy: false,
                              pending: userText, queued: true, loaded: true, permission: nil)
    state.localization.locale = "ar-SA"
    state.localization.language = "ar"
    state.localization.strings["Allow"] = "سماح"
    let data = try JSONEncoder().encode(state)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let chrome = try #require(object["localization"] as? [String: Any])
    #expect(chrome["locale"] as? String == "ar-SA")
    #expect(chrome["language"] as? String == "ar")
    let strings = try #require(chrome["strings"] as? [String: String])
    #expect(strings["Allow"] == "سماح")
    #expect(strings["Copy Code"] != nil && strings["Worked for %@"] != nil)
    let turns = try #require(object["turns"] as? [[String: Any]])
    let blocks = try #require(turns.first?["blocks"] as? [[String: Any]])
    #expect(blocks.first?["text"] as? String == userText)
    #expect(object["pending"] as? String == userText)
}
