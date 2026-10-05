import AppKit
import Foundation
import Observation

/// One bubble of a session's conversation, as `/api/agent/transcript` reads it from the CLI's own
/// transcript: a person's prompt, or everything the agent did until the next one.
struct TranscriptTurn: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: String
    let role: Role
    let timestamp: String?
    /// When the agent was last seen working in this turn.
    let ended: String?
    let model: String?
    let blocks: [TranscriptBlock]

    var text: String {
        blocks.filter { $0.type == .text }.compactMap(\.text).joined(separator: "\n\n")
    }
    var date: Date? { Self.parse(timestamp) }
    var endDate: Date? { Self.parse(ended) }

    static func parse(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return fractional.date(from: timestamp) ?? plain.date(from: timestamp)
    }
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
}

/// Text, thinking, or a tool call with its output and, for a file edit, both sides of it.
struct TranscriptBlock: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, thinking, tool }
    let type: Kind
    let text: String?
    let id: String?
    let name: String?
    let summary: String?
    let command: String?
    let path: String?
    let old: String?
    let new: String?
    let output: String?
    let isError: Bool?
    /// What a tool does, in kinds every CLI shares: `run`, `read`, `edit`, `create`, `search`,
    /// `fetch`, `web`, `delegate`, `plan` or `other`. Its adapter in the backend says, from the
    /// CLI's own tool name, so the page never reads one.
    var kind: String? = nil
}

/// What the agent is doing, as its transcript shows it: `thinking`, or a tool's kind with what it
/// runs or touches. The same for every CLI.
struct AgentActivity: Codable, Equatable, Sendable {
    let kind: String
    var detail: String? = nil
}

struct AgentTranscript: Decodable, Sendable {
    let revision: String
    /// Absent when the caller already holds `revision`.
    let turns: [TranscriptTurn]?
    /// The CLI's hook install: `installed`, `outdated` or `absent`.
    let hooks: String?
    /// When the transcript last showed the agent back at its prompt, with no turn since.
    var atPrompt: String? = nil
    /// What its CLI can do, which the chat goes by instead of the CLI's name.
    var agent: AgentProfile? = nil
    /// What the agent is doing, as its last turn shows it.
    var activity: AgentActivity? = nil
}

/// A file a message carries: placed in the message as a chip, and pasted into the terminal ahead
/// of the message as a drop onto the terminal would paste it, so an agent that attaches a pasted
/// path (Claude Code) gets the file.
struct ChatAttachment: Equatable, Identifiable, Sendable {
    let id = UUID()
    /// The shell-escaped path, as `TerminalPastePayload` types it.
    let path: String
    let name: String

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// A chat view over a session's terminal (prototype). The terminal stays the source of truth: the
/// conversation is read back from the transcript the agent writes, and a sent message is typed
/// into the terminal exactly as a person would paste it.
///
/// The conversation is drawn by the chat page (`ChatPageModel`) in read-only mode, handed the
/// transcript as a thread (`TranscriptPageBackend`); the composer above stays native. Each poll
/// reads the transcript's turns for the agent's state, and the thread when they or the approvals
/// waiting changed, pushing it to the page only when its `snapshotSequence` moved on.
///
/// Typing is only safe at the agent's prompt. While it works, the terminal may be showing a
/// dialog the chat covers, where a letter or an Enter picks an answer; so a message sent then
/// waits for the turn to end, unless the person sends it anyway.
@MainActor @Observable final class TranscriptChatModel {
    /// The conversation as the page shows it.
    struct Thread {
        /// The thread id, project and folder the page shows it under; `readOnly` is set for it.
        var context: ChatPageContext
        /// `{revision, snapshot}` from the transcript endpoint with `format=thread`. Given the last
        /// revision, a backend that can tell may leave `snapshot` out when nothing changed.
        var read: (_ since: String?) async throws -> JSONValue
        /// The chat backend's RPC, for the page's reads of the worktree (`context.cwd`); nil
        /// refuses them.
        var files: (@Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue)? = nil
    }

    /// How the chat reaches its terminal's approval requests.
    struct Permissions {
        /// The terminal's run id, which names it to its hooks; nil until it has started.
        let runID: () -> String?
        let watch: (_ runID: String, _ watcher: PermissionWatcher) -> Void
        let unwatch: (_ runID: String) -> Void
        let answer: (_ id: String, _ decision: String) async throws -> Void
    }

    private(set) var turns: [TranscriptTurn] = []
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var sending = false
    /// A message part-typed, waiting on something the agent asks in the terminal before its next
    /// key. Cancel stops it there.
    private(set) var paused = false
    /// Stops the message being typed at its next key: the chat leaving the screen, the agent
    /// restarting, or Cancel while it is paused.
    @ObservationIgnored private var stopTyping = false
    private(set) var retired = false
    /// A sent message the agent has not written to its transcript yet, shown until it has.
    private(set) var pendingPrompt: String?
    /// A message held until the agent is back at its prompt.
    private(set) var queuedPrompt: String?
    /// The held message's files.
    private(set) var queuedAttachments: [ChatAttachment] = []
    /// Files the next message carries, in the order their marks appear in `draft`.
    private(set) var attachments: [ChatAttachment] = []
    /// A tool approval the agent is waiting on; it is answered here, not in the terminal.
    private(set) var permission: AgentPermissionPrompt?
    /// The CLI's hook install, as the last read reported it.
    private(set) var hooks: String?
    /// What the CLI can do, as the last read reported it.
    @ObservationIgnored private var profile: AgentProfile?
    /// Bumped to hand the keyboard to the message field.
    private(set) var focusRequest = 0
    /// The message being written. Each attached file sits in it as one `ChatCompletion.fileMark`,
    /// which the field draws as a chip: deleting that character in any way (Backspace, Cut, Select
    /// All then Delete) drops the file, and Undo brings it back.
    var draft = "" {
        didSet {
            let marks = ChatCompletion.markCount(in: draft)
            if attachments.count > marks { attachments = Array(attachments.prefix(marks)) }
        }
    }
    /// Where the field's caret is, in UTF-16 units of `draft`; nil while text is selected.
    private(set) var caret: Int?
    /// The list over the field: commands after a leading `/`, files after `@`.
    private(set) var suggestions: [ChatSuggestion] = []
    private(set) var highlighted = 0
    let agentName: String

    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var sentAt: Date?
    @ObservationIgnored private let load: (_ since: String?) async throws -> AgentTranscript
    /// Types a message into the terminal, calling `clear` before each write it makes.
    @ObservationIgnored private let deliver: Deliver
    @ObservationIgnored private let completions: Completions
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let showTerminal: () -> Void
    /// Opens a link from the conversation beside it; false when it cannot, and the system browser does.
    @ObservationIgnored private let openLink: (URL) -> Bool
    /// Opens a file the conversation names, at a line when it gives one.
    @ObservationIgnored private let openFile: (_ path: String, _ line: Int?) -> Void
    /// Fork Session: a new session carrying this conversation on.
    @ObservationIgnored private let forkSession: () -> Void
    @ObservationIgnored private let thread: Thread
    @ObservationIgnored private let makePage: (ChatPageContext, any ChatPageBackend) -> ChatPageModel
    /// The thread's revision as last read, which the next read passes as `since`.
    @ObservationIgnored private var threadRevision: String?
    /// The newest `snapshotSequence` the page has been given.
    @ObservationIgnored private var shownSequence: Double = -1
    /// The transcript or the approvals changed since the thread was last read.
    @ObservationIgnored private var threadStale = true
    @ObservationIgnored private var readingThread = false
    @ObservationIgnored private var watchedRun: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var idle = false
    /// An approval or a question may be up in the terminal, which typed keys would answer.
    @ObservationIgnored private var asking = false
    /// When the agent was last seen starting work: a hook's turn start, or a message typed here.
    /// A transcript's word that it is at its prompt counts only if it is newer than this.
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var transcriptAtPrompt: Date?
    @ObservationIgnored private var agentStartedAt: Date?
    /// Seen at its prompt since it started. Until then a message is held, not typed: a question the
    /// agent asks first (trust this folder, review its hooks) sits in the terminal under the chat.
    @ObservationIgnored private var ready = false
    /// The first report decides `ready` even when it matches the defaults.
    @ObservationIgnored private var stateReported = false
    /// The word the list is for, and one the person closed the list on.
    @ObservationIgnored private var completing: ChatCompletion.Word?
    @ObservationIgnored private var dismissed: ChatCompletion.Word?
    @ObservationIgnored private var commands: [AgentCommand]?
    @ObservationIgnored private var commandsRead: Date?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    /// Built on first show and kept while the model lives, so switching back is immediate.
    private(set) var page: ChatPageModel?

    typealias Deliver = (_ text: String, _ attachments: [ChatAttachment],
                         _ clear: @escaping @MainActor () async throws -> Void) async throws -> Void

    /// Where the list over the field gets its rows. Either may be missing, and then offers none.
    struct Completions {
        /// The CLI's commands in this worktree.
        var commands: (() async -> [AgentCommand])?
        /// Worktree files matching what follows `@`, best first.
        var files: ((_ query: String) async -> [String])?

        init(commands: (() async -> [AgentCommand])? = nil, files: ((_ query: String) async -> [String])? = nil) {
            self.commands = commands
            self.files = files
        }
    }

    init(agentName: String,
         load: @escaping (_ since: String?) async throws -> AgentTranscript,
         deliver: @escaping Deliver,
         completions: Completions = Completions(),
         permissions: Permissions,
         thread: Thread,
         showTerminal: @escaping () -> Void = {},
         openLink: @escaping (URL) -> Bool = { _ in false },
         openFile: @escaping (_ path: String, _ line: Int?) -> Void = { _, _ in },
         fork: @escaping () -> Void = {},
         makePage: @escaping (ChatPageContext, any ChatPageBackend) -> ChatPageModel = { ChatPageModel(context: $0, backend: $1) }) {
        self.agentName = agentName
        self.load = load
        self.deliver = deliver
        self.completions = completions
        self.permissions = permissions
        var thread = thread
        thread.context.readOnly = true
        self.thread = thread
        self.showTerminal = showTerminal
        self.openLink = openLink
        self.openFile = openFile
        self.forkSession = fork
        self.makePage = makePage
    }

    var canSend: Bool {
        !retired && !sending && queuedPrompt == nil && staging == 0
            && (!attachments.isEmpty || !ChatCompletion.text(of: draft).isEmpty)
    }
    /// Files can be added until a message is held; the held one keeps its own.
    var canAttach: Bool { !retired && queuedPrompt == nil }

    /// Places files at the caret, or at the end with no caret; a file already in the message is
    /// not placed twice.
    func attach(_ files: [ChatAttachment]) {
        guard canAttach else { return }
        var added: [ChatAttachment] = []
        for file in files where !(attachments + added).contains(where: { $0.path == file.path }) { added.append(file) }
        guard !added.isEmpty else { return }
        let text = draft as NSString
        let at = min(caret ?? text.length, text.length)
        let before = ChatCompletion.markCount(in: text.substring(to: at))
        let marks = String(repeating: ChatCompletion.fileMark, count: added.count)
        attachments.insert(contentsOf: added, at: before)
        draft = text.replacingCharacters(in: NSRange(location: at, length: 0), with: marks)
        caret = at + marks.utf16.count
    }

    /// The field changed: its text with a mark for each file, the files in order, and its caret.
    func edit(_ text: String, files: [ChatAttachment], caret: Int?) {
        guard !retired else { return }
        if attachments != files { attachments = files }
        if draft != text { draft = text }
        if self.caret != caret { self.caret = caret }
        updateSuggestions()
    }

    /// Files still being read or staged (a pasted screenshot, a dropped file), which the next
    /// message waits for rather than going without them.
    private(set) var staging = 0

    /// Attaches what `files` produces once it is ready, holding Send until then.
    func attach(when files: @escaping @MainActor () async -> [ChatAttachment]) {
        guard canAttach else { return }
        staging += 1
        Task { @MainActor [weak self] in
            let ready = await files()
            guard let self else { return }
            self.staging -= 1
            self.attach(ready)
        }
    }

    func removeAttachment(_ id: ChatAttachment.ID) {
        guard !retired, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let offsets = ChatCompletion.markOffsets(in: draft)
        attachments.remove(at: index)
        guard offsets.indices.contains(index) else { return }
        draft = (draft as NSString).replacingCharacters(in: NSRange(location: offsets[index], length: 1), with: "")
        if let caret, caret > offsets[index] { self.caret = caret - 1 }
    }
    /// A held message can be pushed through by hand, except while an approval card is up: the
    /// agent is stopped on that, and typed keys would land in its prompt.
    var canSendQueuedNow: Bool { !retired && !sending && queuedPrompt != nil && permission == nil }

    func requestFocus() { if !retired { focusRequest &+= 1 } }
    func zoom(_ delta: Double?) {
        guard !retired, let webView = page?.webView else { return }
        TranscriptChatZoom.step(delta, from: webView)
    }

    /// Fork Session is offered once the agent has answered: there is a conversation to carry on.
    var canFork: Bool { !retired && turns.contains { $0.role == .assistant } }
    func fork() { if canFork { forkSession() } }

    /// Polls only while shown. An unchanged transcript answers with its revision alone.
    func appear() {
        guard !retired, polling == nil else { return }
        if page == nil {
            let backend = TranscriptPageBackend(
                read: { [weak self] in
                    guard let self else { throw TranscriptPageBackend.unavailable }
                    return try await self.readThread()
                },
                respond: { [weak self] id, decision in
                    guard let self else { throw TranscriptPageBackend.unavailable }
                    return try await self.respond(to: id, decision: decision)
                },
                worktree: thread.context.cwd,
                files: thread.files)
            let page = makePage(thread.context, backend)
            page.onEvent = { [weak self] event in self?.pageEvent(event) }
            if let webView = page.webView { TranscriptChatZoom.attach(webView) }
            self.page = page
        }
        // Holds the model only while it polls, so a model nobody keeps ends its loop.
        polling = Task { [weak self] in
            while !Task.isCancelled, await self?.poll() == true {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll() async -> Bool {
        guard !retired else { return false }
        watchPermissions()
        await refresh()
        return true
    }

    private func pageEvent(_ event: ChatPageEvent) {
        guard !retired else { return }
        switch event {
        case .openLink(let url):
            if !openLink(url) { NSWorkspace.shared.open(url) }
        case .openFile(let path, let line):
            openFile(path, line)
        case .revealFile(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        // A transcript has no turn diffs of the chat engine's, no providers to manage, and no
        // other chats to open.
        case .openTurnDiff, .openSettings, .openThread:
            break
        }
    }

    // MARK: The page's thread

    /// Reads the thread for the page, which asks when it comes up and when it wants it again.
    private func readThread() async throws -> JSONValue {
        guard !retired else { throw TranscriptPageBackend.unavailable }
        let reply = try await thread.read(nil)
        guard !retired else { throw TranscriptPageBackend.unavailable }
        if let revision = reply["revision"]?.string { threadRevision = revision }
        let snapshot = reply["snapshot"] ?? .null
        if let sequence = snapshot["snapshotSequence"]?.number { shownSequence = max(shownSequence, sequence) }
        return snapshot
    }

    /// Reads the thread again when the transcript or its approvals changed, and gives it to the
    /// page only when it moved on from what the page has.
    func refreshThread() async {
        guard !retired, let page, threadStale, !readingThread else { return }
        threadStale = false
        readingThread = true
        defer { readingThread = false }
        do {
            let reply = try await thread.read(threadRevision)
            guard !retired else { return }
            let revision = reply["revision"]?.string
            // Left out: the backend says nothing changed since `threadRevision`.
            guard let snapshot = reply["snapshot"], let sequence = snapshot["snapshotSequence"]?.number,
                  snapshot["thread"].map({ !$0.isNull }) == true else {
                if let revision { threadRevision = revision }
                return
            }
            if sequence <= shownSequence || page.receiveSnapshot(snapshot) {
                shownSequence = max(shownSequence, sequence)
                if let revision { threadRevision = revision }
            }
        } catch {
            // Read again on the next poll.
            threadStale = true
        }
    }

    /// The page's answer to the approval it shows: `allow` or `deny` for its accept or decline,
    /// and to the terminal for one the app knows is too long to have been shown whole.
    private func respond(to id: String, decision: String) async throws -> JSONValue {
        guard !retired, var answer = TranscriptPageBackend.decision(decision) else { throw TranscriptPageBackend.unavailable }
        if answer == "allow", permission?.id == id, permission?.truncated == true { answer = "pass" }
        if permission?.id == id { permission = nil }
        try await permissions.answer(id, answer)
        guard !retired else { throw TranscriptPageBackend.unavailable }
        if answer == "pass" { showTerminal() }
        threadStale = true
        await refreshThread()
        return ["sequence": .number(max(shownSequence, 0))]
    }

    /// The agent's state as the terminal's hooks report it: working, or known to be at its prompt;
    /// whether it may be asking something in the terminal; and when this app started it, if it did.
    func setAgentState(busy: Bool, idle: Bool, asking: Bool = false, startedAt: Date? = nil) {
        guard !retired, !stateReported || self.busy != busy || self.idle != idle || self.asking != asking
                || agentStartedAt != startedAt else { return }
        stateReported = true
        if busy, !self.busy { busySince = Date() }
        if agentStartedAt != startedAt {
            agentStartedAt = startedAt; ready = false
            // What a message being typed has typed went to the agent that ended.
            if sending { stopTyping = true }
        }
        self.busy = busy
        self.idle = idle
        self.asking = asking
        settle()
    }

    /// Past whatever the agent asks before its prompt: a shell that was already running, a turn
    /// the hooks heard, or the transcript showing it at its prompt since it started. Once past,
    /// it stays past for this start.
    private func updateReady() {
        guard !ready else { return }
        let seenAtPrompt = agentStartedAt.map { started in transcriptAtPrompt.map { $0 > started } ?? false } ?? true
        ready = seenAtPrompt || idle || busy
    }

    /// Back at its prompt since it last started work: after its turn's end (the hooks), or after
    /// an interrupt or a turn Codex marked as done (the transcript), which no hook reports.
    private var returnedToPrompt: Bool {
        guard let transcriptAtPrompt else { return false }
        return busySince.map { transcriptAtPrompt > $0 } ?? true
    }
    /// Known to be at its prompt, where typing into the terminal cannot answer a dialog.
    var atPrompt: Bool { ready && (idle || returnedToPrompt) }

    /// Working, in a CLI that queues what it is sent meanwhile, with nothing asked in the terminal.
    /// Only the installed hook reports every approval and question as it goes up.
    private var takesMidTurn: Bool {
        profile?.queuesMidTurn == true && ready && busy && !asking && hooks == "installed"
    }

    /// A message typed now reaches the agent, not a prompt of its own.
    var deliverable: Bool { atPrompt || takesMidTurn }

    /// Shows the agent's state, and sends a held message once it can take it.
    private func settle() {
        updateReady()
        // Asked again when the task runs: a prompt may have gone up in the terminal meanwhile.
        if deliverable, queuedPrompt != nil { Task { if deliverable { await sendQueued() } } }
    }

    func disappear() {
        // Never finished into a terminal the person may be typing in now.
        if sending { stopTyping = true }
        polling?.cancel()
        polling = nil
        if let run = watchedRun { permissions.unwatch(run) }
        watchedRun = nil
        permission = nil
        threadStale = true
    }

    /// Follows the terminal's run id, which a restart changes; a terminal still starting has none.
    private func watchPermissions() {
        guard !retired else { return }
        let run = permissions.runID()
        guard run != watchedRun else { return }
        if let old = watchedRun { permissions.unwatch(old) }
        watchedRun = run
        permission = nil
        threadStale = true
        guard let run else { return }
        permissions.watch(run, PermissionWatcher(
            show: { [weak self] prompt in
                guard let self, !self.retired else { return }
                self.permission = prompt
                // The thread shows the approvals waiting: read it now rather than on the next poll.
                self.threadStale = true
                Task { await self.refreshThread() }
            },
            movedToTerminal: { [weak self] in
                guard let self, !self.retired else { return }
                self.showTerminal()
            }))
    }

    func refresh() async {
        guard !retired else { return }
        do {
            let transcript = try await load(revision)
            guard !retired else { return }
            if let fresh = transcript.turns {
                if fresh != turns { turns = fresh }
                threadStale = true
                // Read with the turns; an unchanged transcript leaves the last word standing.
                transcriptAtPrompt = TranscriptTurn.parse(transcript.atPrompt)
            }
            // Only a prompt written after the send can be it; the transcript may word it
            // differently (a slash command), and its window drops older prompts as it moves.
            if pendingPrompt != nil, let sentAt,
               turns.contains(where: { $0.role == .user && ($0.date ?? .distantPast) >= sentAt.addingTimeInterval(-2) }) {
                pendingPrompt = nil
            }
            revision = transcript.revision
            hooks = transcript.hooks
            profile = transcript.agent
            error = nil
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
        loaded = true
        settle()
        await refreshThread()
    }

    /// Sends at once when the agent can take it; otherwise holds the message until it can.
    func send() async {
        guard canSend else { return }
        queuedPrompt = ChatCompletion.text(of: draft)
        queuedAttachments = attachments
        attachments = []
        draft = ""
        caret = 0
        clearSuggestions()
        if deliverable { await sendQueued() }
    }

    /// Types the held message into the terminal, now, whatever the agent is doing.
    func sendQueuedNow() async {
        guard canSendQueuedNow else { return }
        await sendQueued(byHand: true)
    }

    func cancelQueued() {
        guard !retired else { return }
        // A paused message stops where it is, and comes back as `sendQueued` gives it up.
        if paused { stopTyping = true; return }
        guard !sending, let text = queuedPrompt else { return }
        restoreQueued(text)
    }

    /// Takes the held message back into the field.
    private func restoreQueued(_ text: String) {
        queuedPrompt = nil
        // Its files go back where they were, ahead of anything written since.
        attachments = queuedAttachments + attachments
        draft = String(repeating: ChatCompletion.fileMark, count: queuedAttachments.count) + (draft.isEmpty ? text : draft)
        caret = (draft as NSString).length
        queuedAttachments = []
    }

    private struct TypingStopped: Error {}

    private func sendQueued(byHand: Bool = false) async {
        guard !retired, !sending, permission == nil, let text = queuedPrompt else { return }
        let files = queuedAttachments
        sending = true
        stopTyping = false
        typedSome = false
        defer { sending = false }
        do {
            // Mid-turn the agent can put up a prompt between one key and the next, so each waits
            // for it. Pushed through by hand, the message goes regardless.
            try await deliver(text, files) { [weak self] in
                guard let self else { return }
                if !byHand { try await clearToType() }
                typedSome = true
            }
            guard !retired else { return }
            queuedPrompt = nil
            queuedAttachments = []
            sentAt = Date()
            // It is working on this now, whatever the transcript last said.
            busySince = sentAt
            pendingPrompt = Self.shown(text, with: files)
            error = nil
            await refresh()
        } catch is TypingStopped {
            guard !retired else { return }
            restoreQueued(text)
            if typedSome {
                self.error = String(localized: "\(agentName) asked something in the terminal as this message was typed. It was not sent: what was typed is in \(agentName)'s prompt there.")
            }
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
    }

    @ObservationIgnored private var typedSome = false

    /// Waits, before each key of a message, while the agent is working and may be asking something
    /// in the terminal: the key would answer it, and Enter would take its first choice. The turn's
    /// end closes whatever it asked. Claude draws its prompt a moment before its hook is heard, so
    /// a key can still land in that moment, as one typed in the terminal itself could.
    private func clearToType() async throws {
        defer { if paused { paused = false } }
        while true {
            guard !retired, !stopTyping else { throw TypingStopped() }
            // At its prompt nothing comes up by itself; mid-turn anything may.
            guard permission != nil || (asking && busy), !atPrompt else { return }
            paused = true
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Suggestions

    /// Follows the word at the caret: the CLI's commands after a leading `/`, the worktree's files
    /// after `@`. Closed with Escape, the list stays closed for that word.
    private func updateSuggestions() {
        guard let caret, let word = ChatCompletion.word(in: draft, caret: caret) else { return clearSuggestions() }
        if let dismissed, dismissed.kind == word.kind, dismissed.range.location == word.range.location {
            return clearSuggestions(keepDismissed: true)
        }
        dismissed = nil
        let sameWord = completing?.kind == word.kind && completing?.range.location == word.range.location
        let changed = completing?.query != word.query || !sameWord
        completing = word
        switch word.kind {
        case .command:
            if let commands { show(ChatCompletion.commands(commands, matching: word.query).map(ChatCompletion.suggestion(for:)), reset: changed) }
            // Read once, then again after a while: a command written meanwhile shows up.
            if commandsRead.map({ Date().timeIntervalSince($0) > 30 }) ?? true { readCommands() }
        case .file:
            guard changed, completions.files != nil else { return }
            lookup?.cancel()
            // Asked once typing pauses, and only the latest word's answer is shown.
            lookup = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let files = self?.completions.files else { return }
                let found = await files(word.query)
                guard !Task.isCancelled, let self, self.completing == word else { return }
                self.show(found.prefix(50).map(ChatCompletion.suggestion(forFile:)), reset: true)
            }
        }
    }

    private func readCommands() {
        guard completions.commands != nil else { return }
        commandsRead = Date()
        Task { [weak self] in
            guard let read = self?.completions.commands else { return }
            let found = await read()
            guard let self, !self.retired else { return }
            self.commands = found
            if let word = self.completing, word.kind == .command {
                self.show(ChatCompletion.commands(found, matching: word.query).map(ChatCompletion.suggestion(for:)), reset: false)
            }
        }
    }

    private func show(_ rows: [ChatSuggestion], reset: Bool) {
        if suggestions != rows { suggestions = rows }
        highlighted = reset ? 0 : min(highlighted, max(rows.count - 1, 0))
    }

    private func clearSuggestions(keepDismissed: Bool = false) {
        lookup?.cancel()
        lookup = nil
        completing = nil
        if !keepDismissed { dismissed = nil }
        if !suggestions.isEmpty { suggestions = [] }
        highlighted = 0
    }

    func moveHighlight(_ step: Int) {
        guard !retired, !suggestions.isEmpty else { return }
        highlighted = (highlighted + step + suggestions.count) % suggestions.count
    }

    /// Escape: the list closes for this word, and opens again for the next.
    func dismissSuggestions() {
        guard !retired, let completing else { return }
        dismissed = completing
        clearSuggestions(keepDismissed: true)
    }

    /// Puts the row in place of the word being completed. With `run`, a command that takes no
    /// arguments is sent too, as Enter on it does in the terminal.
    func acceptSuggestion(_ index: Int? = nil, run: Bool = false) async {
        guard !retired, let word = completing else { return }
        let index = index ?? highlighted
        guard suggestions.indices.contains(index) else { return }
        let row = suggestions[index]
        let text = draft as NSString
        guard NSMaxRange(word.range) <= text.length else { return clearSuggestions() }
        draft = text.replacingCharacters(in: word.range, with: row.insert)
        caret = word.range.location + (row.insert as NSString).length
        clearSuggestions()
        requestFocus()
        if run, row.complete { await send() }
    }

    /// A sent message as its bubble shows it until the transcript has it: the files by name.
    static func shown(_ text: String, with files: [ChatAttachment]) -> String {
        let names = files.map(\.name).joined(separator: ", ")
        return [names, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func retire() {
        retired = true
        clearSuggestions()
        disappear()
        page?.retire()
        page = nil
    }
}
