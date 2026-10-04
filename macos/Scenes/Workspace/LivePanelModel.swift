import Foundation
import Observation

/// What the Live tab draws of a session's agent, read from its transcript: how many calls each
/// kind of tool has had, which are running, the latest calls and the subagents of the turn. The
/// same for every CLI: it goes by the kinds the backend's adapters name, never a tool's name.
struct LiveActivity: Equatable {
    /// A box of the panel: the tool kinds, folded into the six a reader tells apart.
    enum Lane: String, CaseIterable {
        case read, search, edit, run, web, delegate
        init?(kind: String?) {
            switch kind {
            case "read": self = .read
            case "search": self = .search
            case "edit", "create", "patch": self = .edit
            case "run": self = .run
            case "fetch", "web": self = .web
            case "delegate": self = .delegate
            default: return nil
            }
        }
        var title: String {
            switch self {
            case .read: String(localized: "Read")
            case .search: String(localized: "Search")
            case .edit: String(localized: "Edit")
            case .run: String(localized: "Run")
            case .web: String(localized: "Web")
            case .delegate: String(localized: "Agents")
            }
        }
        var symbol: String {
            switch self {
            case .read: "doc.text"
            case .search: "magnifyingglass"
            case .edit: "pencil"
            case .run: "terminal"
            case .web: "globe"
            case .delegate: "person.2"
            }
        }
    }

    /// One tool call: what it touched or ran, whether it is still running, and whether it failed.
    /// `time` is its turn's: the transcript dates turns, not calls. `kind` is the backend's.
    struct Call: Equatable, Identifiable {
        let id: String
        let lane: Lane?
        let label: String
        var running: Bool
        var failed: Bool
        var kind: String? = nil
        var path: String? = nil
        var time: Date? = nil
        /// A subagent's kind, as its hooks name it.
        var agentType: String? = nil
    }

    /// The log keeps this many of the latest calls — as many as a tall pane shows — and the files
    /// box this many files.
    static let logLength = 40, fileCount = 3

    var counts: [Lane: Int] = [:]
    var calls = 0
    var failures = 0
    var prompts = 0
    var model: String?
    /// The lanes with a call running in the turn under way.
    var running: Set<Lane> = []
    /// The latest calls, oldest first.
    var log: [Call] = []
    /// The subagents of the last turn that started any, oldest first; or, as the hooks report
    /// them, the latest subagents from their start to their stop.
    var subagents: [Call] = []
    /// The most subagents kept to draw.
    static let subagentCount = 12
    /// The files edited or created last, newest first, each once; an edit that failed changed
    /// nothing, and is left out.
    var files: [Call] = []
    /// Each lane's latest call.
    var latest: [Lane: Call] = [:]
    /// Every call the transcript holds, by id.
    var ids: Set<String> = []

    /// A call with no output yet is running only while the agent is at work: one left without
    /// output by an interrupted turn is not.
    static func of(_ turns: [TranscriptTurn], busy: Bool) -> LiveActivity {
        var activity = LiveActivity()
        var all: [Call] = []
        let current = turns.last?.role == .assistant ? turns.last?.id : nil
        for turn in turns {
            if turn.role == .user { activity.prompts += 1; continue }
            var delegates: [Call] = []
            defer { if !delegates.isEmpty { activity.subagents = delegates } }
            if let model = turn.model { activity.model = model }
            let date = turn.date
            for (index, block) in turn.blocks.enumerated() where block.type == .tool {
                let lane = Lane(kind: block.kind)
                let running = busy && turn.id == current && block.output == nil
                let call = Call(id: block.id ?? "\(turn.id)#\(index)", lane: lane,
                                label: label(of: block), running: running, failed: block.isError == true,
                                kind: block.kind, path: block.path, time: date)
                all.append(call)
                activity.ids.insert(call.id)
                activity.calls += 1
                if call.failed { activity.failures += 1 }
                if let lane {
                    activity.counts[lane, default: 0] += 1
                    activity.latest[lane] = call
                    if running { activity.running.insert(lane) }
                }
                if lane == .delegate { delegates.append(call) }
            }
        }
        activity.log = Array(all.suffix(logLength))
        var seen = Set<String>()
        activity.files = Array(all.reversed().filter { call in
            guard call.lane == .edit, !call.failed, let path = call.path, !path.isEmpty else { return false }
            return seen.insert(path).inserted
        }.prefix(fileCount))
        return activity
    }

    /// This, with what the tool hooks have said since (`AgentToolFeed`): a call the transcript
    /// holds takes the time it really started at, and stops running the moment it ends; one it does
    /// not hold yet is drawn already, counted and logged. Subagents heard of are drawn from their
    /// start to their stop, each told by the call that started it.
    func merging(_ heard: AgentToolFeed.Heard, busy: Bool) -> LiveActivity {
        let feed = heard.calls
        guard !feed.isEmpty || !heard.subagents.isEmpty else { return self }
        var merged = self
        let byID = Dictionary(feed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func update(_ call: Call) -> Call {
            guard let hook = byID[call.id] else { return call }
            var call = call
            call.time = hook.started
            if hook.ended != nil { call.running = false; call.failed = call.failed || hook.failed }
            return call
        }
        merged.log = log.map(update)
        merged.subagents = subagents.map(update)
        merged.latest = latest.mapValues(update)
        // A call the hook says ended runs no more, nor does its lane unless another of its calls
        // still runs; one that failed by its hook counts as failed before the transcript says so.
        let known = Dictionary((log + subagents + Array(latest.values)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let endedLanes = Set(feed.filter { $0.ended != nil }.compactMap { known[$0.id]?.lane })
        let stillRunning = Set((merged.log + merged.subagents + Array(merged.latest.values)).filter(\.running).compactMap(\.lane))
        merged.running = running.subtracting(endedLanes).union(stillRunning)
        merged.failures += feed.filter { hook in hook.failed && known[hook.id].map { !$0.failed } == true }.count
        for hook in feed where !ids.contains(hook.id) {
            let lane = Lane(kind: hook.kind), running = busy && hook.ended == nil
            let call = Call(id: hook.id, lane: lane, label: hook.label, running: running, failed: hook.failed,
                            kind: hook.kind, time: hook.started)
            merged.calls += 1
            if call.failed { merged.failures += 1 }
            if let lane {
                merged.counts[lane, default: 0] += 1
                merged.latest[lane] = call
                if running { merged.running.insert(lane) }
            }
            if lane == .delegate { merged.subagents.append(call) }
            merged.log.append(call)
        }
        merged.log = Array(merged.log.suffix(Self.logLength))
        if !heard.subagents.isEmpty {
            // Newest first, each subagent takes the latest call that started by then, asked for its
            // kind, and was not already taken: parallel calls go to their subagents in order, and a
            // call that never started one (denied, failed) is passed over. All of them are paired
            // before the latest few are kept, in the order they started.
            var calls = feed.filter { Lane(kind: $0.kind) == .delegate && !$0.failed }
            let paired = heard.subagents.sorted { $0.started > $1.started }.map { subagent -> Call in
                let index = calls.indices.filter { index in
                    calls[index].started <= subagent.started.addingTimeInterval(1)
                        && (calls[index].agentType == nil || subagent.type == nil || calls[index].agentType == subagent.type)
                }.max { calls[$0].started < calls[$1].started }
                let label = index.map { calls.remove(at: $0).label } ?? subagent.type ?? ""
                return Call(id: subagent.id, lane: .delegate, label: label, running: subagent.ended == nil, failed: false,
                            kind: "delegate", time: subagent.started, agentType: subagent.type)
            }
            merged.subagents = Array(paired.reversed().suffix(Self.subagentCount))
            if merged.subagents.contains(where: \.running) { merged.running.insert(.delegate) }
        }
        return merged
    }

    private static func label(of block: TranscriptBlock) -> String {
        let text = [block.summary, block.command, block.path, block.name].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// The Live tab's model: the session's transcript, read once a second while the tab is on screen,
/// and what the panel draws of it, in the theme the person picked. A hidden session's view stays
/// mounted, so the view's appearing is not enough: each pass asks `visible` first, and reads
/// nothing while the tab is out of sight.
/// It reads apart from the chat's model; with both shown that is two light requests a second, the
/// revision answering for an unchanged transcript.
@MainActor @Observable final class LivePanelModel {
    /// What the transcript shows, as last read.
    private(set) var transcript = LiveActivity()
    /// What the panel draws: the transcript, and what the tool hooks have said since.
    var activity: LiveActivity { transcript.merging(feed(), busy: busy()) }
    /// The look every Live tab is drawn in: a preference, kept across launches.
    private(set) var theme: LiveTheme
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var retired = false

    @ObservationIgnored private let load: (_ since: String?) async throws -> AgentTranscript
    @ObservationIgnored private let busy: () -> Bool
    @ObservationIgnored private let visible: () -> Bool
    @ObservationIgnored private let feed: () -> AgentToolFeed.Heard
    @ObservationIgnored private var turns: [TranscriptTurn] = []
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private let defaults: UserDefaults
    static let themeKey = "live.theme"
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(load: @escaping (_ since: String?) async throws -> AgentTranscript, busy: @escaping () -> Bool,
         visible: @escaping () -> Bool = { true }, feed: @escaping () -> AgentToolFeed.Heard = { .init() },
         defaults: UserDefaults = .standard) {
        self.load = load
        self.busy = busy
        self.visible = visible
        self.feed = feed
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeKey).flatMap(LiveTheme.init(rawValue:)) ?? .native
    }

    func setTheme(_ value: LiveTheme) {
        guard !retired, value != theme else { return }
        theme = value
        defaults.set(value.rawValue, forKey: Self.themeKey)
    }

    /// Whether the panel should be moving: the tab on screen.
    var isVisible: Bool { !retired && visible() }

    /// Reads only while on screen. An unchanged transcript answers with its revision alone.
    func appear() {
        guard !retired, polling == nil else { return }
        // Holds the model only while it polls, so a model nobody keeps ends its loop.
        polling = Task { [weak self] in
            while !Task.isCancelled, await self?.poll() == true {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func poll() async -> Bool {
        guard !retired else { return false }
        if visible() { await refresh() }
        return true
    }
    func disappear() {
        guard !retired else { return }
        polling?.cancel(); polling = nil
    }
    func retire() {
        retired = true
        polling?.cancel(); polling = nil
    }

    func refresh() async {
        guard !retired else { return }
        do {
            let transcript = try await load(revision)
            guard !retired else { return }
            if let fresh = transcript.turns { turns = fresh }
            revision = transcript.revision
            error = nil
        } catch {
            guard !retired else { return }
            // The last turns stay drawn, and what was running stops with the agent. Before any read
            // there is nothing to draw.
            self.error = error.localizedDescription
            guard loaded else { return }
        }
        // Read on every pass, changed transcript or not: the agent stopping ends what was running.
        let next = LiveActivity.of(turns, busy: busy())
        if next != transcript { transcript = next }
        loaded = true
    }
}
