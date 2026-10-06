import Foundation
import Observation

/// Every chat the backend keeps, for the sidebar and Projects: read whole once connected, then
/// kept by the backend's `chat-shell` (a chat was made, renamed, archived, or its state moved) and
/// `chat-removed` events. Archived chats are kept here and left out of what lists show.
@MainActor @Observable final class ChatListStore {
    private(set) var shells: [String: ChatThreadShell] = [:]
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private var service: (any ChatServing)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    /// What events said while a listing was on its way, which the listing must not undo: a shell
    /// heard of, or nil for one removed.
    @ObservationIgnored private var heardDuringLoad: [String: ChatThreadShell?] = [:]
    @ObservationIgnored private var loading = false
    /// After each listing, whether or not it worked.
    @ObservationIgnored var onLoad: () -> Void = {}

    func connect(_ service: (any ChatServing)?) {
        self.service = service
        loadTask?.cancel(); loadTask = nil
        generation = UUID()
        if service == nil { loading = false; heardDuringLoad = [:]; return }
        reload()
    }

    /// Reads the list again: on connecting, and after a reconnect, when events may have been missed.
    func reload() {
        guard let service else { return }
        let generation = UUID()
        self.generation = generation
        loading = true
        heardDuringLoad = [:]
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let listed = try await service.listThreads()
                guard let self, self.generation == generation else { return }
                var next = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for (id, heard) in heardDuringLoad { next[id] = heard }
                finishLoad()
                if shells != next { shells = next }
                loaded = true; error = nil
                onLoad()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                finishLoad()
                self.error = error.localizedDescription
                onLoad()
            }
        }
    }

    private func finishLoad() { loading = false; heardDuringLoad = [:]; loadTask = nil }

    /// Waits for the listing under way, for tests.
    func settle() async { await loadTask?.value }

    /// A `chat-shell` event, or a shell the app already has in hand (one it just made).
    func receive(_ shell: ChatThreadShell) {
        if loading { heardDuringLoad[shell.id] = .some(shell) }
        if shells[shell.id] != shell { shells[shell.id] = shell }
    }

    /// A `chat-shell` event as it came: one this build cannot read is left for the next listing.
    func receive(shell value: JSONValue) {
        guard let shell = try? value.decode(ChatThreadShell.self) else { return }
        receive(shell)
    }

    /// A `chat-removed` event, or a chat deleted here.
    func remove(_ id: String) {
        if loading { heardDuringLoad[id] = .some(nil) }
        if shells[id] != nil { shells[id] = nil }
    }

    func shell(_ id: String) -> ChatThreadShell? { shells[id] }

    /// The chats lists show, newest first by creation, so a row does not jump each time it is used.
    /// A subagent's thread is left out unless asked for: it is reached from its parent's page. So is
    /// a chat started in a session's pane, tagged with a worktree in `excludingWorktrees`: the
    /// session shows it. Once the session is gone, its chats are listed again.
    func visible(includeArchived: Bool = false, includeSubagents: Bool = false,
                 excludingWorktrees: Set<String> = []) -> [ChatThreadShell] {
        shells.values.filter {
            (includeArchived || !$0.archived) && (includeSubagents || !$0.subagent)
                && !Self.inSession($0, worktrees: excludingWorktrees)
        }.sorted {
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
    }

    /// The chats started in the panes of the session working in `worktree`, and their forks: not
    /// archived, not a subagent's, newest first. What a pane's new-chat form offers to open again.
    func inWorktree(_ worktree: String) -> [ChatThreadShell] {
        let target: Set<String> = [Self.standardized(worktree)]
        return visible().filter { Self.inSession($0, worktrees: target) }
    }

    /// Whether `shell` was started in the pane of a session working in one of `worktrees`
    /// (standardized paths, as `standardized` makes them).
    static func inSession(_ shell: ChatThreadShell, worktrees: Set<String>) -> Bool {
        guard !worktrees.isEmpty, let path = shell.worktreePath, !path.isEmpty else { return false }
        return worktrees.contains(standardized(path))
    }
    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// The visible chats by where lists put them: each known project's under it, and every other —
    /// standalone, or a project that is gone — under Other Chats.
    func grouped(projectIDs: Set<String>, includeArchived: Bool = false,
                 excludingWorktrees: Set<String> = []) -> (byProject: [String: [ChatThreadShell]], standalone: [ChatThreadShell]) {
        var byProject: [String: [ChatThreadShell]] = [:]
        var standalone: [ChatThreadShell] = []
        for shell in visible(includeArchived: includeArchived, excludingWorktrees: excludingWorktrees) {
            if projectIDs.contains(shell.projectId) { byProject[shell.projectId, default: []].append(shell) }
            else { standalone.append(shell) }
        }
        return (byProject, standalone)
    }
}
