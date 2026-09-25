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
}

struct AgentTranscript: Decodable, Sendable {
    let revision: String
    /// Absent when the caller already holds `revision`.
    let turns: [TranscriptTurn]?
    /// The CLI's hook install: `installed`, `outdated` or `absent`.
    let hooks: String?
    /// When the transcript last showed the agent back at its prompt, with no turn since.
    var atPrompt: String? = nil
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
/// Typing is only safe at the agent's prompt. While it works, the terminal may be showing a
/// dialog the chat covers, where a letter or an Enter picks an answer; so a message sent then
/// waits for the turn to end, unless the person sends it anyway.
@MainActor @Observable final class TranscriptChatModel {
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
    /// Bumped to hand the keyboard to the message field.
    private(set) var focusRequest = 0
    /// Whether the chat is drawn over the terminal. Not until the agent has been seen at its prompt
    /// since it started: a question it asks first is the terminal's to show and answer.
    private(set) var coversTerminal = false
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
    @ObservationIgnored private let deliver: (_ text: String, _ attachments: [ChatAttachment]) async throws -> Void
    @ObservationIgnored private let completions: Completions
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let showTerminal: () -> Void
    @ObservationIgnored let openHookSettings: () -> Void
    /// Opens a link from the conversation beside it; false when it cannot, and the system browser does.
    @ObservationIgnored private let openLink: (URL) -> Bool
    @ObservationIgnored private var watchedRun: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var idle = false
    /// When the agent was last seen starting work: a hook's turn start, or a message typed here.
    /// A transcript's word that it is at its prompt counts only if it is newer than this.
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var transcriptAtPrompt: Date?
    @ObservationIgnored private var agentStartedAt: Date?
    @ObservationIgnored private var ready = false
    /// The first report decides the cover even when it matches the defaults.
    @ObservationIgnored private var stateReported = false
    /// The word the list is for, and one the person closed the list on.
    @ObservationIgnored private var completing: ChatCompletion.Word?
    @ObservationIgnored private var dismissed: ChatCompletion.Word?
    @ObservationIgnored private var commands: [AgentCommand]?
    @ObservationIgnored private var commandsRead: Date?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    /// Built on first show and kept while the model lives, so switching back is immediate.
    private(set) var page: TranscriptChatPage?

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
         deliver: @escaping (_ text: String, _ attachments: [ChatAttachment]) async throws -> Void,
         completions: Completions = Completions(),
         permissions: Permissions,
         showTerminal: @escaping () -> Void = {},
         openHookSettings: @escaping () -> Void = {},
         openLink: @escaping (URL) -> Bool = { _ in false }) {
        self.agentName = agentName
        self.load = load
        self.deliver = deliver
        self.completions = completions
        self.permissions = permissions
        self.showTerminal = showTerminal
        self.openHookSettings = openHookSettings
        self.openLink = openLink
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

    /// Why the chat cannot do everything the terminal does, when it cannot.
    var hookNotice: String? {
        switch hooks {
        case "absent": "Without the \(agentName) hook, Cascade can't always tell when \(agentName) is working: a message may wait for Send Now, and approvals appear in the terminal."
        case "outdated": "Update the \(agentName) hook to answer approvals here. Until then they appear in the terminal: if \(agentName) seems stuck, switch to it."
        default: nil
        }
    }

    func requestFocus() { if !retired { focusRequest &+= 1 } }
    func zoom(_ delta: Double?) { if !retired { page?.zoom(delta) } }

    /// Polls only while shown. An unchanged transcript answers with its revision alone.
    func appear() {
        guard !retired, polling == nil else { return }
        if page == nil {
            let page = TranscriptChatPage()
            page.onPermission = { [weak self] id, decision in Task { await self?.answerPermission(id, decision: decision) } }
            page.onOpen = { [weak self] url in
                guard let self, !self.retired else { return false }
                return self.openLink(url)
            }
            self.page = page
            render()
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

    /// The agent's state as the terminal's hooks report it: working, or known to be at its prompt;
    /// and when this app started it, if it did.
    func setAgentState(busy: Bool, idle: Bool, startedAt: Date? = nil) {
        guard !retired, !stateReported || self.busy != busy || self.idle != idle || agentStartedAt != startedAt else { return }
        stateReported = true
        if busy, !self.busy { busySince = Date() }
        if agentStartedAt != startedAt { agentStartedAt = startedAt; ready = false }
        self.busy = busy
        self.idle = idle
        settle()
    }

    /// Draws the chat over the terminal now, for an agent past its questions that said nothing.
    func openChat() {
        guard !retired, !coversTerminal else { return }
        ready = true
        settle()
    }

    /// Past whatever the agent asks before its prompt: a shell that was already running, a turn
    /// the hooks heard, or the transcript showing it at its prompt since it started. Once past,
    /// it stays past for this start.
    private func updateCover() {
        if !ready {
            let seenAtPrompt = agentStartedAt.map { started in transcriptAtPrompt.map { $0 > started } ?? false } ?? true
            ready = seenAtPrompt || idle || busy
        }
        if coversTerminal != ready { coversTerminal = ready }
    }

    /// Back at its prompt since it last started work: after its turn's end (the hooks), or after
    /// an interrupt or a turn Codex marked as done (the transcript), which no hook reports.
    private var returnedToPrompt: Bool {
        guard let transcriptAtPrompt else { return false }
        return busySince.map { transcriptAtPrompt > $0 } ?? true
    }
    /// Known to be at its prompt, where typing into the terminal cannot answer a dialog.
    var atPrompt: Bool { coversTerminal && (idle || returnedToPrompt) }

    /// Shows the agent's state, and sends a held message once it is at its prompt.
    private func settle() {
        updateCover()
        render()
        if atPrompt, queuedPrompt != nil { Task { await sendQueued() } }
    }

    private func render() {
        page?.render(ChatPageState(turns: turns, busy: busy && !returnedToPrompt,
                                   pending: pendingPrompt ?? queuedPrompt.map { Self.shown($0, with: queuedAttachments) },
                                   queued: pendingPrompt == nil && queuedPrompt != nil, loaded: loaded, permission: permission))
    }

    func disappear() {
        polling?.cancel()
        polling = nil
        if let run = watchedRun { permissions.unwatch(run) }
        watchedRun = nil
        permission = nil
        render()
    }

    /// Follows the terminal's run id, which a restart changes; a terminal still starting has none.
    private func watchPermissions() {
        guard !retired else { return }
        let run = permissions.runID()
        guard run != watchedRun else { return }
        if let old = watchedRun { permissions.unwatch(old) }
        watchedRun = run
        permission = nil
        render()
        guard let run else { return }
        permissions.watch(run, PermissionWatcher(
            show: { [weak self] prompt in
                guard let self, !self.retired else { return }
                self.permission = prompt
                self.render()
            },
            movedToTerminal: { [weak self] in
                guard let self, !self.retired else { return }
                self.showTerminal()
            }))
    }

    /// `allow`, `deny`, or `pass`: the card could not show all of it, so the terminal decides.
    func answerPermission(_ id: String, decision: String) async {
        guard !retired, permission?.id == id, ["allow", "deny", "pass"].contains(decision) else { return }
        permission = nil
        render()
        do {
            try await permissions.answer(id, decision)
            error = nil
            if decision == "pass", !retired { showTerminal() }
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        guard !retired else { return }
        do {
            let transcript = try await load(revision)
            guard !retired else { return }
            if let fresh = transcript.turns {
                if fresh != turns { turns = fresh }
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
            error = nil
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
        }
        loaded = true
        settle()
    }

    /// Sends at once at the agent's prompt; otherwise holds the message until it is back there.
    func send() async {
        guard canSend else { return }
        queuedPrompt = ChatCompletion.text(of: draft)
        queuedAttachments = attachments
        attachments = []
        draft = ""
        caret = 0
        clearSuggestions()
        render()
        if atPrompt { await sendQueued() }
    }

    /// Types the held message into the terminal, now, whatever the agent is doing.
    func sendQueuedNow() async {
        guard canSendQueuedNow else { return }
        await sendQueued()
    }

    func cancelQueued() {
        guard !retired, !sending, let text = queuedPrompt else { return }
        queuedPrompt = nil
        // Its files go back where they were, ahead of anything written since.
        attachments = queuedAttachments + attachments
        draft = String(repeating: ChatCompletion.fileMark, count: queuedAttachments.count) + (draft.isEmpty ? text : draft)
        caret = (draft as NSString).length
        queuedAttachments = []
        render()
    }

    private func sendQueued() async {
        guard !retired, !sending, permission == nil, let text = queuedPrompt else { return }
        let files = queuedAttachments
        sending = true
        defer { sending = false }
        do {
            try await deliver(text, files)
            guard !retired else { return }
            queuedPrompt = nil
            queuedAttachments = []
            sentAt = Date()
            // It is working on this now, whatever the transcript last said.
            busySince = sentAt
            pendingPrompt = Self.shown(text, with: files)
            error = nil
            render()
            // A command that opens a panel does so in the terminal, which the chat covers. Files
            // go after a command as its arguments, and one with arguments opens none.
            if files.isEmpty, opensPanel(text) { showTerminal() }
            await refresh()
        } catch {
            guard !retired else { return }
            self.error = error.localizedDescription
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

    /// `/model`, `/config` and the like, sent bare, answer in a panel of the terminal's own.
    private func opensPanel(_ text: String) -> Bool {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return false }
        let name = String(text.dropFirst())
        return commands?.first { $0.name == name }?.interactive == true
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
        page?.close()
        page = nil
    }
}
