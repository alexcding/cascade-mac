import Foundation

struct WorkspaceSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let projectId: String
    let workspace: String
    let worktree: String
    let title: String
    let branch: String
    let url: String
    let createdAt: String?
    var pinned: Bool
    var kind: String? = nil
    var jiraKey: String? = nil
    var cli: String? = nil
    var sessionId: String? = nil
    /// This session's own run destination; empty means it follows the project's.
    var runScheme: String? = nil
    var runSim: String? = nil
    /// The name the user gave it from the sidebar. Display only: the worktree, branch and page
    /// title stay what they were. Empty means it is shown by its worktree folder.
    var name: String? = nil
    /// What a forked session's agent starts from, until its own conversation exists: the backend
    /// sets it, and the app clears it once it resumes the fork's own. Empty for any other session.
    var forkFrom: String? = nil
    /// The session this one was forked from; empty for one that was not. Kept for good.
    var forkedFrom: String? = nil

    var label: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let folder = (worktree as NSString).lastPathComponent
        return folder.isEmpty ? (title.isEmpty ? id : title) : folder
    }
}

enum SidebarDestination: Hashable, Codable {
    case overview, automation, terminal, project(String), session(String)

    /// True for destinations that exist only while the sidebar lists them.
    var isSidebarBacked: Bool {
        switch self {
        case .project, .session: true
        case .overview, .automation, .terminal: false
        }
    }
}

/// What the sidebar knows about a session's agent at render time, drawn as the row's status dot
/// (`SidebarStatusDot`): busy is the agent's colour, waiting on a person is yellow, a turn
/// finished and not yet looked at is green, anything else grey; stopped also dims the row.
struct SidebarSessionStatus: Equatable {
    var live = false
    var busy = false
    var needsInput = false
    var done = false
    var cli: String?
}

struct SidebarEntry: Equatable {
    var isHeading: Bool {
        switch role { case .label, .projectsHeader: true; default: false }
    }
    /// A row with a destination, or a heading whose "+" shows on hover.
    var hoverable: Bool {
        switch role {
        case .projectsHeader(canCreate: true): true
        default: destination != nil
        }
    }
    enum Role: Equatable {
        case nav                                  // Dashboard
        case label                                // "Pinned" heading
        case projectsHeader(canCreate: Bool)      // "Projects" heading with a hover "+" for a new project
        case project
        case session(SidebarSessionStatus, pinned: Bool)
    }

    let id: String // placement identity changes when a session is pinned or unpinned
    let title: String
    let symbol: String
    var detail = ""
    var destination: SidebarDestination?
    var children: [SidebarEntry] = []
    var role: Role = .nav
    var tooltip: String?
    /// A session made by forking another, marked after its name.
    var forked = false

    var isGroup: Bool { destination == nil }
    /// Every destination this entry can take the selection to: a row is its own destination.
    var destinations: [SidebarDestination] { destination.map { [$0] } ?? [] }
    var sessionID: String? { if case .session(let id) = destination { id } else { nil } }
    var projectID: String? { if case .project(let id) = destination { id } else { nil } }

    /// Dashboard, Pinned sessions, then the Projects heading with each folder's unpinned sessions
    /// nested under it, then unpinned sessions whose project is gone (unlabeled). Headings are
    /// flat rows, not collapsible groups — only a project folder collapses.
    static func make(projects: [Project], sessions: [WorkspaceSession],
                     status: [String: SidebarSessionStatus] = [:], order: SidebarOrder = .init(),
                     canCreateProject: Bool = false) -> [Self] {
        let ordered = displayOrder(sessions.filter { !$0.pinned }, dragged: order.sessions)
        let projects = displayOrder(projects, dragged: order.projects)
        func row(_ session: WorkspaceSession, pinned: Bool = false) -> Self {
            let state = status[session.id] ?? SidebarSessionStatus(cli: session.cli)
            var tip = session.worktree
            if !state.live { tip += "\n" + String(localized: "Stopped — click to resume") }
            var entry = Self(id: "\(pinned ? "pin" : "session"):\(session.id)", title: session.label,
                             symbol: "", detail: session.worktree, destination: .session(session.id),
                             role: .session(state, pinned: session.pinned)).withTip(tip)
            entry.forked = session.forkedFrom?.isEmpty == false
            return entry
        }
        func label(_ id: String, _ title: String) -> Self { Self(id: id, title: title, symbol: "", role: .label) }
        var result: [Self] = [
            .init(id: "overview", title: String(localized: "Dashboard"), symbol: "dashboard", destination: .overview),
            .init(id: "automation", title: String(localized: "Automation"), symbol: "automation", destination: .automation)
        ]
        // Pinned lists across projects and has an order of its own: a drag inside one project
        // must not change the order used when sessions are pinned.
        let pinned = displayOrder(sessions.filter(\.pinned), dragged: order.pinned)
        if !pinned.isEmpty {
            result.append(label("label:pinned", String(localized: "Pinned")))
            result += pinned.map { row($0, pinned: true) }
        }
        result.append(Self(id: "label:projects", title: String(localized: "Projects"), symbol: "",
                           role: .projectsHeader(canCreate: canCreateProject)))
        result += projects.map { project in
            .init(id: "project:\(project.id)", title: project.name, symbol: "folder", detail: project.workspace,
                  destination: .project(project.id), children: ordered.filter { $0.projectId == project.id }.map { row($0) },
                  role: .project)
        }
        let projectIDs = Set(projects.map(\.id))
        result += ordered.filter { !projectIDs.contains($0.projectId) }.map { row($0) }
        return result
    }

    /// Projects as the sidebar lists them: dragged order first, then the backend's.
    static func displayOrder(_ projects: [Project], dragged: [String]) -> [Project] {
        let rank = Dictionary(dragged.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return projects.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id] ?? Int.max, r = rank[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Sessions as the sidebar lists them: dragged order first, then creation order.
    static func displayOrder(_ sessions: [WorkspaceSession], dragged: [String]) -> [WorkspaceSession] {
        let rank = Dictionary(dragged.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions.sorted {
            if (rank[$0.id] ?? Int.max) != (rank[$1.id] ?? Int.max) { return (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            if $0.label != $1.label { return $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func withTip(_ value: String) -> Self { var copy = self; copy.tooltip = value; return copy }

    var descendants: [Self] { [self] + children.flatMap(\.descendants) }
}

