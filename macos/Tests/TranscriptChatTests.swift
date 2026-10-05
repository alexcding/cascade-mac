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
    /// How long the command list takes to arrive.
    var commandsDelay: Duration = .zero
    var files: [String] = []
    var fileQueries: [String] = []
    /// What the CLI's profile says: a message typed while it works goes into its own queue.
    var queuesMidTurn = false
    /// The messages whose Enter was pressed.
    var entered: [String] = []
    /// Runs once the text is typed, before its Enter.
    var afterText: () -> Void = {}
    /// What the transcript endpoint answers with `format=thread`, and the `since` of each read.
    var threadReply: JSONValue = ["revision": "t1", "snapshot": ["snapshotSequence": 5, "thread": ["id": "transcript-s1"]]]
    var threadSinces: [String?] = []
    /// What the chat sent its page.
    var outputs: [ChatPageOutput] = []
    var threadPushes: [JSONValue] {
        outputs.compactMap { if case .push("thread", let value) = $0 { value } else { nil } }
    }
    var forks = 0
    /// The session's worktree, as the page's context names it.
    var cwd = "/work"
    /// The page's reads of the worktree, as they reached the chat backend.
    var folderReads: [(String, JSONValue)] = []
    /// The files the page asked to open.
    var opened: [String] = []

    /// Held strongly by what it builds: a send can finish after the test that started it.
    func model() -> TranscriptChatModel {
        TranscriptChatModel(
            agentName: "Claude",
            load: { _ in
                var transcript = self.transcript
                transcript.agent = AgentProfile(id: "cli", queuesMidTurn: self.queuesMidTurn)
                return transcript
            },
            deliver: { text, files, clear in
                try await clear()
                self.pasted.append(files.map(\.path))
                self.typed.append(text)
                self.afterText()
                try await clear()
                self.entered.append(text)
            },
            completions: .init(
                commands: { try? await Task.sleep(for: self.commandsDelay); return self.commands },
                files: { query in self.fileQueries.append(query); return self.files }),
            permissions: .init(
                runID: { self.runID },
                watch: { run, watcher in self.watched.append(run); self.watcher = watcher },
                unwatch: { run in self.unwatched.append(run) },
                answer: { id, decision in self.answers.append((id, decision)) }),
            thread: .init(context: ChatPageContext(threadId: "transcript-s1", projectId: "p1", cwd: cwd, projectName: "Work"),
                          read: { since in self.threadSinces.append(since); return self.threadReply },
                          files: { @MainActor method, params in
                              self.folderReads.append((method, params))
                              return ["read": .string(method)]
                          }),
            showTerminal: { self.terminalShown += 1 },
            openFile: { path, _ in self.opened.append(path) },
            fork: { self.forks += 1 },
            makePage: { context, backend in
                ChatPageModel(context: context, backend: backend, copy: { _ in }, output: { self.outputs.append($0) })
            })
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

@Test func theTranscriptCarriesTheProfileTheBackendSends() throws {
    // `Profile` in crates/cascade-backend/src/agents/mod.rs, as it serializes.
    let json = #"{"revision":"r","turns":[],"hooks":"installed","agent":{"id":"claude","queuesMidTurn":true}}"#
    let transcript = try JSONDecoder().decode(AgentTranscript.self, from: Data(json.utf8))
    #expect(transcript.agent == AgentProfile(id: "claude", queuesMidTurn: true))
}

@Test func theTranscriptCarriesWhatTheAgentIsDoing() throws {
    // As `transcript::read` writes it: each tool call's kind, and the call still out.
    let json = #"{"revision":"r","hooks":"installed","activity":{"kind":"run","detail":"Run the tests"},"turns":[{"id":"a","role":"assistant","blocks":[{"type":"tool","name":"Bash","kind":"run","summary":"Run the tests"}]}]}"#
    let transcript = try JSONDecoder().decode(AgentTranscript.self, from: Data(json.utf8))
    #expect(transcript.activity == AgentActivity(kind: "run", detail: "Run the tests"))
    #expect(transcript.turns?.first?.blocks.first?.kind == "run")
}

@MainActor @Test func claudeTakesAMessageWhileItWorksAsItsTerminalWould() async {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "and the tests"
    await chat.send()
    #expect(fixture.entered == ["and the tests"] && chat.queuedPrompt == nil)
    #expect(chat.pendingPrompt == "and the tests")
}

@MainActor @Test func aMessageWaitsWhileClaudeMayBeAskingInTheTerminal() async throws {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false, asking: true)
    chat.draft = "and the tests"
    await chat.send()
    // Its Enter would pick the question's first answer, or allow the tool.
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "and the tests")
    chat.setAgentState(busy: true, idle: false, asking: false)
    try await eventually { fixture.entered == ["and the tests"] }
}

@MainActor @Test func aPromptThatGoesUpMidMessageHoldsItsEnterUntilItIsAnswered() async throws {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false)
    fixture.afterText = { chat.setAgentState(busy: true, idle: false, asking: true) }
    chat.draft = "and the tests"
    let sending = Task { await chat.send() }
    try await eventually { fixture.typed == ["and the tests"] }
    try? await Task.sleep(for: .milliseconds(300))
    // Enter would take the prompt's first choice.
    #expect(fixture.entered.isEmpty && chat.sending && chat.paused)
    fixture.afterText = {}
    chat.setAgentState(busy: true, idle: false, asking: false)
    await sending.value
    #expect(fixture.entered == ["and the tests"] && chat.queuedPrompt == nil)
}

@MainActor @Test func aPausedMessageStopsWhereItIsAndComesBackToTheField() async throws {
    for stop in ["cancel", "leave", "restart"] {
        let fixture = ChatFixture()
        fixture.queuesMidTurn = true
        let chat = fixture.model()
        await chat.refresh()
        chat.setAgentState(busy: true, idle: false)
        fixture.afterText = { chat.setAgentState(busy: true, idle: false, asking: true) }
        chat.draft = "and the tests"
        let sending = Task { await chat.send() }
        try await eventually { chat.paused }
        switch stop {
        case "cancel": chat.cancelQueued()
        case "leave": chat.disappear()
        default: chat.setAgentState(busy: false, idle: false, asking: false, startedAt: Date())
        }
        await sending.value
        // Nothing more is typed, and the text left in the terminal's prompt is said to be there.
        #expect(fixture.typed == ["and the tests"] && fixture.entered.isEmpty, "\(stop)")
        #expect(chat.queuedPrompt == nil && chat.draft == "and the tests" && !chat.sending && !chat.paused, "\(stop)")
        #expect(chat.error != nil, "\(stop)")
    }
}

@MainActor @Test func aMessagePushedThroughByHandDoesNotWaitForAPrompt() async {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false, asking: true)
    chat.draft = "go anyway"
    await chat.send()
    await chat.sendQueuedNow()
    #expect(fixture.entered == ["go anyway"])
}

@MainActor @Test func aPromptThatGoesUpBeforeTheHeldMessageIsTypedStopsIt() async {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false, asking: true)
    chat.draft = "and the tests"
    await chat.send()
    // Clear for a moment, then asked again before the send it set off has run.
    chat.setAgentState(busy: true, idle: false, asking: false)
    chat.setAgentState(busy: true, idle: false, asking: true)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "and the tests")
}

@MainActor @Test func withoutItsHookClaudeIsTypedIntoOnlyOnceItsTurnEnds() async throws {
    let fixture = ChatFixture()
    fixture.queuesMidTurn = true
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "absent")
    let chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "and the tests"
    await chat.send()
    // No hook to report an approval as it goes up.
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "and the tests")
    try? await Task.sleep(for: .milliseconds(20))
    fixture.transcript = AgentTranscript(revision: "r2", turns: [], hooks: "absent", atPrompt: stamp(Date()))
    await chat.refresh()
    try await eventually { fixture.entered == ["and the tests"] }
}

@MainActor @Test func aCLIThatDoesNotQueueIsTypedIntoOnlyAtItsPrompt() async {
    let fixture = ChatFixture(), chat = fixture.model()
    await chat.refresh()
    chat.setAgentState(busy: true, idle: false)
    chat.draft = "and the tests"
    await chat.send()
    #expect(fixture.typed.isEmpty && chat.queuedPrompt == "and the tests")
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

@MainActor @Test func aJustStartedAgentHoldsAMessageUntilItIsAtItsPrompt() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let started = Date()
    // Resumed into its old conversation: the transcript's last turn end is from before this start,
    // and the agent may be asking to trust its hooks in the terminal right now.
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(started.addingTimeInterval(-60)))
    chat.setAgentState(busy: false, idle: false, startedAt: started)
    await chat.refresh()
    #expect(!chat.atPrompt)
    chat.draft = "hello"
    await chat.send()
    #expect(fixture.typed.isEmpty, "Nothing is typed into a question the chat would hide")
    fixture.transcript = AgentTranscript(revision: "r2", turns: [], hooks: "installed", atPrompt: stamp(started.addingTimeInterval(1)))
    await chat.refresh()
    try? await eventually { fixture.typed == ["hello"] }
    #expect(fixture.typed == ["hello"], "Seen at its prompt since it started, so the held message goes")
}

@MainActor @Test func theHooksHearingItAtItsPromptSendsTheHeldMessage() async {
    let fixture = ChatFixture(), chat = fixture.model()
    let started = Date()
    chat.setAgentState(busy: false, idle: false, startedAt: started)
    chat.draft = "hello"
    await chat.send()
    #expect(fixture.typed.isEmpty && !chat.atPrompt)
    chat.setAgentState(busy: false, idle: true, startedAt: started)
    #expect(chat.atPrompt)
    try? await eventually { fixture.typed == ["hello"] }
    #expect(fixture.typed == ["hello"])
}

@MainActor @Test func aShellThatWasAlreadyRunningTakesAMessageAtOnce() async {
    let fixture = ChatFixture(), chat = fixture.model()
    fixture.transcript = AgentTranscript(revision: "r1", turns: [], hooks: "installed", atPrompt: stamp(Date().addingTimeInterval(-60)))
    chat.setAgentState(busy: false, idle: false, startedAt: nil)
    await chat.refresh()
    #expect(chat.atPrompt)
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

private func command(_ name: String, _ description: String = "", hint: String = "", source: String = "builtin") -> AgentCommand {
    AgentCommand(name: name, description: description, hint: hint, source: source, plugin: nil)
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

@MainActor @Test func aBareCommandStaysInTheChat() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("model", hint: "[model]")]
    let chat = fixture.model()
    chat.setAgentState(busy: false, idle: true)
    chat.edit("/mo", files: [], caret: 3)
    try await eventually { !chat.suggestions.isEmpty }
    await chat.acceptSuggestion()
    await chat.send()
    #expect(fixture.typed == ["/model"] && fixture.terminalShown == 0)
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

@MainActor @Test func escapeBeforeTheCommandsArriveKeepsTheListClosed() async throws {
    let fixture = ChatFixture()
    fixture.commands = [command("compact")]
    fixture.commandsDelay = .milliseconds(200)
    let chat = fixture.model()
    chat.edit("/c", files: [], caret: 2)
    chat.dismissSuggestions()
    try await Task.sleep(for: .milliseconds(400))
    #expect(chat.suggestions.isEmpty, "The list that was loading stays closed")
    chat.edit("/co", files: [], caret: 3)
    #expect(chat.suggestions.isEmpty, "Still closed while the same word is typed")
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
    fixture.commands = [command("model", hint: "[model]")]
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

private func answer(_ id: String, _ decision: String) -> JSONValue {
    ["kind": "request", "id": .string("req-\(id)-\(decision)"), "method": "orchestration.dispatchCommand",
     "params": ["command": ["type": "thread.approval.respond", "threadId": "transcript-s1", "requestId": .string(id),
                            "decision": .string(decision)]]]
}

private let pageReady: JSONValue = ["kind": "event", "name": "ready", "payload": [:]]

/// The page gets the transcript as a read-only thread, and a new snapshot only once it moved on:
/// a read that comes back with the same sequence, or with none (unchanged since), sends nothing.
@MainActor @Test func theTranscriptPageGetsASnapshotOnlyWhenItMovesOn() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.appear()
    chat.disappear()
    let page = try #require(chat.page)
    page.receive(message: pageReady)
    try await eventually { fixture.threadPushes.count == 1 }
    let context = try #require(fixture.outputs.first.flatMap { if case .push("context", let value) = $0 { value } else { nil } })
    #expect(context["readOnly"] == true && context["threadId"] == "transcript-s1")
    #expect(fixture.threadSinces == [nil], "The page's own read is a whole one")
    #expect(fixture.threadPushes[0]["snapshot"]?["snapshotSequence"] == 5)

    await chat.refresh()
    #expect(fixture.threadSinces.last == "t1" && fixture.threadPushes.count == 1, "The same sequence again is not pushed")

    fixture.threadReply = ["revision": "t2", "snapshot": ["snapshotSequence": 9, "thread": ["id": "transcript-s1"]]]
    await chat.refresh()
    #expect(fixture.threadPushes.count == 2 && fixture.threadPushes[1]["snapshot"]?["snapshotSequence"] == 9)

    // A backend that can tell answers an unchanged thread with its revision alone.
    fixture.threadReply = ["revision": "t2"]
    await chat.refresh()
    fixture.threadReply = ["revision": "t1", "snapshot": ["snapshotSequence": 7, "thread": ["id": "transcript-s1"]]]
    await chat.refresh()
    #expect(fixture.threadPushes.count == 2, "Nothing unchanged or older goes to the page")
    #expect(fixture.threadSinces.last == "t2")
    chat.retire()
}

/// The approval the page shows is answered through the permission route: accept allows, decline
/// and cancel deny, and one too long to have been shown whole goes to the terminal instead.
@MainActor @Test func theTranscriptPageAnswersApprovalsThroughThePermissionRoute() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.appear()
    defer { chat.retire() }
    let page = try #require(chat.page)
    page.receive(message: pageReady)
    try await eventually { fixture.watcher != nil && !fixture.threadPushes.isEmpty }
    let reads = fixture.threadSinces.count
    page.receive(message: answer("p1", "accept"))
    page.receive(message: answer("p2", "decline"))
    page.receive(message: answer("p3", "cancel"))
    page.receive(message: answer("p4", "acceptForSession"))
    try await eventually { fixture.answers.count == 4 }
    #expect(Set(fixture.answers.map { "\($0.0)=\($0.1)" }) == ["p1=allow", "p2=deny", "p3=deny", "p4=allow"])
    func replies() -> [JSONValue] { fixture.outputs.compactMap { if case .reply(_, let value) = $0 { value } else { nil } } }
    try await eventually { replies().count == 4 }
    #expect(replies().allSatisfy { $0["ok"] == true && $0["result"]?["sequence"] != nil })
    #expect(fixture.threadSinces.count > reads, "An answer reads the thread again")

    fixture.watcher?.show(AgentPermissionPrompt(id: "p5", details: .init(tool: "Bash", detail: "x", reason: "", truncated: true)))
    page.receive(message: answer("p5", "accept"))
    try await eventually { fixture.answers.count == 5 }
    #expect(fixture.answers.last! == ("p5", "pass") && fixture.terminalShown == 1 && chat.permission == nil)
}

/// The page cannot continue a terminal's conversation: anything but an approval is refused.
@Test func theTranscriptPageRefusesWhatOnlyTheTerminalCanDo() async throws {
    let backend = TranscriptPageBackend(read: { ["snapshotSequence": 1, "thread": ["id": "t"]] },
                                        respond: { _, _ in ["sequence": 1] })
    for (method, params) in [("orchestration.dispatchCommand", ["command": ["type": "thread.turn.start"]] as JSONValue),
                             ("provider.listModels", ["provider": "claudeAgent"]), ("attachments.save", [:]),
                             // No chat backend to read the worktree through.
                             ("projects.readFile", ["cwd": "/work", "relativePath": "a"])] {
        do { _ = try await backend.call(method, params: params); Issue.record("\(method) was answered") }
        catch let error as ChatRPCError { #expect(error.code == "unavailable") }
    }
    let unknown: JSONValue = ["command": ["type": "thread.approval.respond", "requestId": "p", "decision": "maybe"]]
    do { _ = try await backend.call("orchestration.dispatchCommand", params: unknown); Issue.record("An unknown decision was sent") }
    catch let error as ChatRPCError { #expect(error.code == "invalid") }
    #expect(try await backend.call("orchestration.getThreadDetailSnapshot", params: ["threadId": "t"])["snapshotSequence"] == 1)
    #expect(try await backend.providers() == [])
}

/// The page's file-reference previews read the worktree through the chat backend: as the
/// worktree, whatever folder or thread the page named, since the transcript is not a chat.
@MainActor @Test func theTranscriptPageReadsTheWorktreeThroughTheChatBackend() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.appear()
    defer { chat.retire() }
    let page = try #require(chat.page)
    for method in ["projects.searchEntries", "projects.readFile", "projects.resolveWorkspaceFileReferences"] {
        page.receive(message: ["kind": "request", "id": .string(method), "method": .string(method),
                               "params": ["cwd": "/elsewhere", "threadId": "transcript-s1", "query": "a"]])
    }
    try await eventually { fixture.folderReads.count == 3 }
    #expect(Set(fixture.folderReads.map(\.0)) == ChatFileAccess.folderMethods)
    #expect(fixture.folderReads.allSatisfy { $0.1["cwd"] == "/work" && $0.1["threadId"] == nil && $0.1["query"] == "a" })
    func replies() -> [JSONValue] { fixture.outputs.compactMap { if case .reply(_, let value) = $0 { value } else { nil } } }
    try await eventually { replies().count == 3 }
    #expect(replies().allSatisfy { $0["ok"] == true && $0["result"]?["read"] != nil })
}

/// A file the transcript names opens in the session's pane only when it is inside the worktree.
@MainActor @Test func theTranscriptPageOpensOnlyWorktreeFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-files-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let worktree = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: worktree.appendingPathComponent("a.swift"))
    try Data("b".utf8).write(to: root.appendingPathComponent("b.txt"))
    let fixture = ChatFixture()
    fixture.cwd = worktree.path
    let chat = fixture.model()
    chat.appear()
    defer { chat.retire() }
    let page = try #require(chat.page)
    for path in ["../b.txt", root.appendingPathComponent("b.txt").path, "/etc/hosts", "a.swift"] {
        page.receive(message: ["kind": "event", "name": "openFile", "payload": ["path": .string(path)]])
    }
    #expect(fixture.opened == [ChatFileAccess.real(worktree.appendingPathComponent("a.swift").path)!])
}

/// Fork Session carries the whole conversation on, so the chat offers it (beside the composer's
/// attach button) once the agent has answered, and not before.
@MainActor @Test func theChatOffersForkOnceTheAgentHasAnswered() async throws {
    let fixture = ChatFixture(), chat = fixture.model()
    chat.fork()
    #expect(!chat.canFork && fixture.forks == 0, "Nothing to carry on yet")
    let question = try JSONDecoder().decode([TranscriptTurn].self, from: Data("""
        [{"id":"u1","role":"user","blocks":[{"type":"text","text":"one"}]}]
        """.utf8))
    fixture.transcript = AgentTranscript(revision: "r1", turns: question, hooks: "installed")
    await chat.refresh()
    chat.fork()
    #expect(!chat.canFork && fixture.forks == 0, "A question alone is not a conversation to fork")
    let answered = try JSONDecoder().decode([TranscriptTurn].self, from: Data("""
        [{"id":"u1","role":"user","blocks":[{"type":"text","text":"one"}]},
         {"id":"a1","role":"assistant","blocks":[{"type":"text","text":"first"}]}]
        """.utf8))
    fixture.transcript = AgentTranscript(revision: "r2", turns: answered, hooks: "installed")
    await chat.refresh()
    #expect(chat.canFork)
    chat.fork()
    #expect(fixture.forks == 1)
    chat.retire()
    chat.fork()
    #expect(fixture.forks == 1, "A retired chat forks nothing")
}
