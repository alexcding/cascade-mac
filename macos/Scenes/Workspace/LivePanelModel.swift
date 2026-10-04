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
            case "edit", "create": self = .edit
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
        let running: Bool
        let failed: Bool
        var kind: String? = nil
        var path: String? = nil
        var time: Date? = nil
    }

    /// The log keeps this many of the latest calls, and the files box this many files.
    static let logLength = 6, fileCount = 3

    var counts: [Lane: Int] = [:]
    var calls = 0
    var failures = 0
    var prompts = 0
    var model: String?
    /// The lanes with a call running in the turn under way.
    var running: Set<Lane> = []
    /// The latest calls, oldest first.
    var log: [Call] = []
    /// The subagents the turn under way started, oldest first.
    var subagents: [Call] = []
    /// The files edited or created last, newest first, each once; an edit that failed changed
    /// nothing, and is left out.
    var files: [Call] = []

    /// A call with no output yet is running only while the agent is at work: one left without
    /// output by an interrupted turn is not.
    static func of(_ turns: [TranscriptTurn], busy: Bool) -> LiveActivity {
        var activity = LiveActivity()
        var all: [Call] = []
        let current = turns.last?.role == .assistant ? turns.last?.id : nil
        for turn in turns {
            if turn.role == .user { activity.prompts += 1; continue }
            if let model = turn.model { activity.model = model }
            let date = turn.date
            for (index, block) in turn.blocks.enumerated() where block.type == .tool {
                let lane = Lane(kind: block.kind)
                let running = busy && turn.id == current && block.output == nil
                let call = Call(id: block.id ?? "\(turn.id)#\(index)", lane: lane,
                                label: label(of: block), running: running, failed: block.isError == true,
                                kind: block.kind, path: block.path, time: date)
                all.append(call)
                activity.calls += 1
                if call.failed { activity.failures += 1 }
                if let lane { activity.counts[lane, default: 0] += 1; if running { activity.running.insert(lane) } }
                if turn.id == current, lane == .delegate { activity.subagents.append(call) }
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

    private static func label(of block: TranscriptBlock) -> String {
        let text = [block.summary, block.command, block.path, block.name].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// A call seen start: a packet the panel sends from the agent to its lane.
struct LivePulse: Equatable, Identifiable {
    let id: String
    let lane: LiveActivity.Lane
    let start: Date
    /// How long a packet takes down its wire.
    static let duration: TimeInterval = 0.9
}

/// The Live tab's model: the session's transcript, read once a second while the tab is on screen,
/// and what the panel draws of it. A call that appears between two reads sends a packet down its
/// lane. A hidden session's view stays mounted, so the view's appearing is not enough: each pass
/// asks `visible` first, and reads nothing while the tab is out of sight.
/// It reads apart from the chat's model; with both shown that is two light requests a second, the
/// revision answering for an unchanged transcript.
@MainActor @Observable final class LivePanelModel {
    private(set) var activity = LiveActivity()
    private(set) var pulses: [LivePulse] = []
    private(set) var loaded = false
    private(set) var error: String?
    private(set) var retired = false

    @ObservationIgnored private let load: (_ since: String?) async throws -> AgentTranscript
    @ObservationIgnored private let busy: () -> Bool
    @ObservationIgnored private let visible: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var turns: [TranscriptTurn] = []
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var seen: Set<String> = []
    /// Out of sight since the last read: what happened meanwhile is history, not news.
    @ObservationIgnored private var away = false
    @ObservationIgnored private var polling: Task<Void, Never>?

    init(load: @escaping (_ since: String?) async throws -> AgentTranscript, busy: @escaping () -> Bool,
         visible: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init) {
        self.load = load
        self.busy = busy
        self.visible = visible
        self.now = now
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
        if visible() { await refresh() } else { away = true }
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
            // The last turns stay drawn; what was running stops with the agent, and packets expire.
            // Before any read there is nothing to draw, and the first read must still count as one.
            self.error = error.localizedDescription
            guard loaded else { return }
        }
        // Read on every pass, changed transcript or not: the agent stopping ends what was running.
        let next = LiveActivity.of(turns, busy: busy())
        let at = now()
        let ids = Set(turns.flatMap { turn in
            turn.blocks.enumerated().compactMap { index, block in block.type == .tool ? block.id ?? "\(turn.id)#\(index)" : nil }
        })
        // What was there at the first read, or came while the tab was away, is history: no packets.
        let started = loaded && !away ? ids.subtracting(seen) : []
        if error == nil { away = false }
        let fresh = turns.flatMap { turn in
            turn.blocks.enumerated().compactMap { index, block -> LivePulse? in
                let id = block.id ?? "\(turn.id)#\(index)"
                guard block.type == .tool, started.contains(id), let lane = LiveActivity.Lane(kind: block.kind) else { return nil }
                return LivePulse(id: id, lane: lane, start: at)
            }
        }
        seen = ids
        let kept = pulses.filter { at.timeIntervalSince($0.start) < LivePulse.duration } + fresh
        if kept != pulses { pulses = kept }
        if next != activity { activity = next }
        loaded = true
    }
}
