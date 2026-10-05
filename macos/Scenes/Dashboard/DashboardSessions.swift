import Foundation

/// A session as Projects shows it: what the app already knows of it, with nothing asked of the
/// backend. Its agent's state comes from its terminal and the CLI's hooks (`AgentTurnTracker`),
/// so a session whose terminal is not attached reads as stopped, and one whose CLI has no hooks
/// shows no calls.
struct DashboardSession: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        /// A question or an approval waits on the user.
        case needsYou
        /// The agent is mid-turn.
        case working
        /// A turn ended that nobody has looked at yet.
        case finished
        /// The agent waits at its prompt.
        case idle
        /// No terminal runs it.
        case stopped
    }

    /// One tool call the hooks reported: its kind (Bash, Edit) and what it acted on.
    struct Call: Equatable, Sendable {
        let kind: String?
        let label: String
        let started: Date
        var ended: Date?
        /// The kind and its target, whichever of the two the hook named.
        var text: String { [kind, label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    let id: String
    let projectID: String
    /// The session's own label: the name it was given, else its worktree's folder.
    let title: String
    let branch: String
    let ticket: String?
    let cli: String?
    let state: State
    /// The agent's latest call, nil before its first or with no hooks.
    var call: Call?
    /// When its agent started, while its terminal runs one.
    var agentStarted: Date?
    /// Whether a terminal runs it: a finished turn whose terminal has since closed has no prompt.
    var live = true
}

/// A chat session as Projects lists it under its project: what the chat backend last reported.
struct DashboardChat: Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let title: String
    let cli: String?
    let working: Bool
    let needsInput: Bool
    /// What a person reads in its state column.
    var stateLabel: String {
        needsInput ? String(localized: "Needs you") : working ? String(localized: "Working") : String(localized: "Idle")
    }
    var stage: DashboardSessionStage { needsInput ? .needsYou : working ? .working : .idle }
}

/// What a session needs next, the board's columns on Projects, in their order.
enum DashboardSessionStage: String, CaseIterable, Identifiable, Sendable {
    case needsYou, working, inReview, idle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .inReview: String(localized: "In review")
        case .idle: String(localized: "Idle")
        }
    }
}

/// One session's row: the session, the open pull request on its branch, and its stage.
struct DashboardSessionRow: Equatable, Identifiable, Sendable {
    let session: DashboardSession
    /// The open pull request whose head is the session's branch, in the session's project.
    let pr: DashboardRow?
    var id: String { session.id }

    /// An answer waiting outranks everything; then a turn under way; then an open pull request.
    var stage: DashboardSessionStage {
        switch session.state {
        case .needsYou: .needsYou
        case .working: .working
        case .finished, .idle, .stopped: pr == nil ? .idle : .inReview
        }
    }

    /// The row's state word: the stage, but a finished turn and a stopped agent say so.
    var stateLabel: String {
        switch session.state {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .finished: String(localized: "Finished")
        case .idle: pr == nil ? String(localized: "Idle") : String(localized: "In review")
        case .stopped: String(localized: "Stopped")
        }
    }

    /// The activity in two parts, as the row sets them: the tool or state, a little heavier, then
    /// what it acted on.
    var activityParts: (lead: String, rest: String) {
        switch session.state {
        case .needsYou: return (String(localized: "Waiting"), String(localized: "for your answer"))
        case .working:
            // Between calls the last one is over: the agent is thinking, not still running it.
            guard let call = session.call, call.ended == nil else { return (String(localized: "Thinking"), "") }
            return call.kind.map { ($0, call.label) } ?? (call.label, "")
        case .finished, .idle:
            if let call = session.call { return (String(localized: "Last:"), call.text) }
            return session.live ? (String(localized: "At its prompt"), "") : (String(localized: "Turn finished"), "")
        case .stopped: return (String(localized: "Stopped"), "")
        }
    }

    /// The second line under the session's name: its branch and its ticket, a dash with none.
    var detail: String { "\(session.branch) · \(session.ticket.flatMap { $0.isEmpty ? nil : $0 } ?? "—")" }

    /// Whether the timing changes within the minute: a call under way, drawn every few seconds.
    /// Otherwise it moves by the minute.
    var ticksBySecond: Bool { session.state == .working && session.call.map { $0.ended == nil } == true }

    /// How long the current call and the agent have run, as of `now`.
    func timing(now: Date) -> String {
        var parts: [String] = []
        if session.state == .working, let call = session.call, call.ended == nil {
            parts.append(String(localized: "running \(Self.duration(now.timeIntervalSince(call.started)))"))
        }
        // Under a minute moves by the second, which only a call under way is drawn often enough for.
        if [.finished, .idle].contains(session.state), let ended = session.call?.ended {
            let seconds = now.timeIntervalSince(ended)
            return seconds < 60 ? String(localized: "finished just now") : String(localized: "finished \(Self.duration(seconds)) ago")
        }
        if let started = session.agentStarted {
            let seconds = now.timeIntervalSince(started)
            parts.append(seconds < 60 && !ticksBySecond ? String(localized: "agent just started")
                         : String(localized: "agent up \(Self.duration(seconds))"))
        }
        if parts.isEmpty, session.state == .stopped { return String(localized: "terminal closed") }
        return parts.joined(separator: " · ")
    }

    /// 12s, 4m, 2h 14m.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
    }
}

/// How a project is drawn, as the app has it: the symbol chosen for it.
struct DashboardProjectLook: Equatable, Sendable {
    var symbol: String
}

/// A project on Projects with its sessions, each in stage order.
struct DashboardSessionLane: Equatable, Identifiable, Sendable {
    let summary: DashboardProjectSummary
    /// Its repository, `owner/name`, as the snapshot names it.
    var repo = ""
    var look: DashboardProjectLook?
    let rows: [DashboardSessionRow]
    /// Its chat sessions, newest first.
    var chats: [DashboardChat] = []
    var id: String { summary.id }
}

extension DashboardViewModel {
    /// Every project's lane: its numbers and its sessions, each matched to the open pull request on
    /// its branch. Worked out with the summaries, never per redraw.
    func makeSessionLanes(_ summaries: [DashboardProjectSummary]) -> [DashboardSessionLane] {
        // The user's own pull requests: another person's from a fork can share a branch's name.
        let open = prs.mine
        let order = Dictionary(uniqueKeysWithValues: DashboardSessionStage.allCases.enumerated().map { ($1, $0) })
        let byProject = Dictionary(grouping: sessions, by: \.projectID)
        let chatsByProject = Dictionary(grouping: chats, by: \.projectID)
        return summaries.map { summary in
            let rows = (byProject[summary.id] ?? []).map { session in
                DashboardSessionRow(session: session, pr: open.first {
                    $0.projectID == session.projectID && !session.branch.isEmpty && $0.pr.headRefName == session.branch
                })
            }
            // Stable within a stage: the sessions keep the app's own order.
            let sorted = rows.enumerated().sorted { (order[$0.element.stage]!, $0.offset) < (order[$1.element.stage]!, $1.offset) }.map(\.element)
            return DashboardSessionLane(summary: summary, repo: prs.projects.first { $0.id == summary.id }?.repo ?? "",
                                        look: projectLooks[summary.id], rows: sorted, chats: chatsByProject[summary.id] ?? [])
        }
    }

    /// The lanes Projects shows: the picked project's, or every project's.
    var shownSessionLanes: [DashboardSessionLane] {
        project.map { id in sessionLanes.filter { $0.id == id } } ?? sessionLanes
    }

    /// The board under the lanes: the shown sessions by what they need next, oldest project first.
    func sessionColumns(_ lanes: [DashboardSessionLane]) -> [(stage: DashboardSessionStage, rows: [DashboardSessionRow])] {
        let rows = lanes.flatMap(\.rows)
        return DashboardSessionStage.allCases.map { stage in (stage, rows.filter { $0.stage == stage }) }
    }
}
