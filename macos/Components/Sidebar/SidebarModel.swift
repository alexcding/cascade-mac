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
    case newSession, overview, automation, terminal, project(String), session(String)
    /// A chat session, by its thread id, listed under Chats.
    case chat(String)

    /// True for destinations that exist only while the sidebar lists them. A chat is listed from
    /// its own store, read apart from the inventory, so it is not checked against the inventory's
    /// rows: a deleted chat leaves by its `chat-removed` event (`AppCoordinator.chatRemoved`).
    var isSidebarBacked: Bool {
        switch self {
        case .project, .session: true
        case .newSession, .overview, .automation, .terminal, .chat: false
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

/// What the sidebar draws of a chat: its agent's state, as the backend last reported it.
struct SidebarChatStatus: Equatable {
    var working = false
    var needsInput = false
    var archived = false
    var cli: String?

    /// The status dot's terms: a chat is never "stopped", its agent starts with each message.
    var session: SidebarSessionStatus { SidebarSessionStatus(live: true, busy: working, needsInput: needsInput, done: false, cli: cli) }
}

/// The archived chats, as the Chats heading's Archived Chats lists them: newest archived first, at
/// most `limit`, each with the place it belongs to (its project, or its folder), and how many more
/// there are. A subagent's thread is reached from its parent's page.
struct SidebarArchivedChats: Equatable {
    struct Item: Equatable { let id: String; let title: String; let place: String }
    var items: [Item] = []
    var more = 0
    static let empty = Self()
    static let limit = 20

    static func of(_ chats: [ChatThreadShell], projects: [Project], limit: Int = limit) -> Self {
        let archived = chats.filter { $0.archived && !$0.subagent }.sorted {
            let l = $0.archivedAt ?? "", r = $1.archivedAt ?? ""
            if l != r { return l > r }
            if ($0.createdAt ?? "") != ($1.createdAt ?? "") { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return Self(items: archived.prefix(max(0, limit)).map { Item(id: $0.id, title: $0.label, place: SidebarEntry.chatPlace($0, projects: names)) },
                    more: max(0, archived.count - max(0, limit)))
    }

    /// The items by place, in the order each place first comes: what the submenu draws under a
    /// header per place.
    var byPlace: [(place: String, items: [Item])] {
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for item in items {
            if groups[item.place] == nil { order.append(item.place) }
            groups[item.place, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

struct SidebarEntry: Equatable {
    var isHeading: Bool {
        switch role { case .label: true; default: false }
    }
    /// A row with a destination: headings don't react to the pointer.
    var hoverable: Bool { destination != nil }
    enum Role: Equatable {
        case nav                                  // Dashboard
        case label                                // "Pinned" and "Projects" headings
        case project
        case session(SidebarSessionStatus, pinned: Bool)
        case chat(SidebarChatStatus)
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
    /// Secondary text after the title: a chat's project, or its folder when it has none.
    var subtitle = ""

    /// Every destination this entry can take the selection to: a row is its own destination.
    var destinations: [SidebarDestination] { destination.map { [$0] } ?? [] }
    var sessionID: String? { if case .session(let id) = destination { id } else { nil } }
    var projectID: String? { if case .project(let id) = destination { id } else { nil } }
    var chatID: String? { if case .chat(let id) = destination { id } else { nil } }

    /// Dashboard, Pinned sessions, then the Projects heading with each folder's unpinned sessions
    /// nested under it, then unpinned sessions whose project is gone (unlabeled). Headings are
    /// flat rows, not collapsible groups — only a project folder collapses.
    ///
    /// The chats close the list under a Chats heading, every one of them, a project's or not, newest
    /// first (as `chats` comes), each with its project's name, or its folder's, after its title. The
    /// heading is there only while there is a chat, archived ones included, so the heading's menu can
    /// always reach them; a chat is started from New Task or a project's
    /// New Chat, and the heading's menu reaches the archived ones.
    static func make(projects: [Project], sessions: [WorkspaceSession],
                     status: [String: SidebarSessionStatus] = [:], order: SidebarOrder = .init(),
                     chats: [ChatThreadShell] = [], hasArchivedChats: Bool = false) -> [Self] {
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
        let projectNames = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func chatRow(_ chat: ChatThreadShell) -> Self {
            let state = SidebarChatStatus(working: chat.working, needsInput: chat.needsInput, archived: chat.archived, cli: chat.cli)
            var tip = chat.cwd
            if chat.archived { tip += "\n" + String(localized: "Archived") }
            var entry = Self(id: "chat:\(chat.id)", title: chat.label, symbol: "chat", detail: chat.cwd,
                             destination: .chat(chat.id), role: .chat(state)).withTip(tip)
            // A chat of its own folder is nowhere to name; a picked folder or a project is.
            entry.subtitle = chat.inScratchFolder ? "" : chatPlace(chat, projects: projectNames)
            return entry
        }
        let projectIDs = Set(projects.map(\.id))
        var result: [Self] = [
            .init(id: "new-session", title: String(localized: "New Task"), symbol: "newSession", destination: .newSession),
            .init(id: "overview", title: String(localized: "Projects"), symbol: "pullRequests", destination: .overview),
            .init(id: "automation", title: String(localized: "Automation"), symbol: "automation", destination: .automation)
        ]
        // Pinned lists across projects and has an order of its own: a drag inside one project
        // must not change the order used when sessions are pinned.
        let pinned = displayOrder(sessions.filter(\.pinned), dragged: order.pinned)
        if !pinned.isEmpty {
            result.append(label("label:pinned", String(localized: "Pinned")))
            result += pinned.map { row($0, pinned: true) }
        }
        result.append(label("label:projects", String(localized: "Projects")))
        result += projects.map { project in
            .init(id: "project:\(project.id)", title: project.name, symbol: project.symbol,
                  detail: project.workspace,
                  destination: .project(project.id),
                  children: ordered.filter { $0.projectId == project.id }.map { row($0) },
                  role: .project)
        }
        result += ordered.filter { !projectIDs.contains($0.projectId) }.map { row($0) }
        if !chats.isEmpty || hasArchivedChats {
            result.append(label(chatsID, String(localized: "Chats")))
            result += chats.map(chatRow)
        }
        return result
    }

    /// The Chats heading's id: its menu lists the archived chats.
    static let chatsID = "label:chats"

    /// Where a chat is, as its row's subtitle and the archived list say: its project's name, or its
    /// folder's; No Project for one in a folder of its own.
    static func chatPlace(_ chat: ChatThreadShell, projects: [String: String]) -> String {
        if let name = projects[chat.projectId] { return name }
        if chat.inScratchFolder { return String(localized: "No Project") }
        let folder = (chat.cwd as NSString).lastPathComponent
        return folder.isEmpty ? String(localized: "No Project") : folder
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

