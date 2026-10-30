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
    /// A chat on a paired Mac, shown read-only: the Mac's id (its certificate's fingerprint) and
    /// the thread's, listed in that Mac's section.
    case remoteChat(peer: String, thread: String)

    /// True for destinations that exist only while the sidebar lists them. A chat is listed from
    /// its own store, read apart from the inventory, so it is not checked against the inventory's
    /// rows: a deleted chat leaves by its `chat-removed` event (`AppCoordinator.chatRemoved`).
    var isSidebarBacked: Bool {
        switch self {
        case .project, .session: true
        case .newSession, .overview, .automation, .terminal, .chat, .remoteChat: false
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
    var cli: String?

    /// The status dot's terms: a chat is never "stopped", its agent starts with each message.
    var session: SidebarSessionStatus { SidebarSessionStatus(live: true, busy: working, needsInput: needsInput, done: false, cli: cli) }
}

/// A paired Mac's section: the Mac, and what it showed when last read.
struct SidebarRemoteSection: Equatable {
    let peer: RemotePeer
    var sessions: [WorkspaceSession] = []
    var chats: [ChatThreadShell] = []
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
        case project                              // in Projects, or pinned (placement id "pin:")
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

    /// Dashboard, Pinned sessions and projects, then the Projects heading with each folder's unpinned sessions
    /// nested under it, then unpinned sessions whose project is gone (unlabeled). Headings are
    /// flat rows, not collapsible groups — only a project folder collapses.
    ///
    /// The chats close this Mac's part under a Chats heading, every one of them, a project's or not,
    /// newest first (as `chats` comes), each by its title alone. The heading is there only while
    /// there is a chat; a chat is started from New Task or a project's New Chat.
    ///
    /// Each paired Mac follows in a section of its own, headed by its name and whether it answers:
    /// its sessions, which run there and are listed only, then its chats, which open read-only.
    static func make(projects: [Project], sessions: [WorkspaceSession],
                     status: [String: SidebarSessionStatus] = [:], order: SidebarOrder = .init(),
                     chats: [ChatThreadShell] = [], remote: [SidebarRemoteSection] = []) -> [Self] {
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
        func chatRow(_ chat: ChatThreadShell) -> Self {
            let state = SidebarChatStatus(working: chat.working, needsInput: chat.needsInput, cli: chat.cli)
            // The Chats section is not a project's: a row is its title alone.
            return Self(id: "chat:\(chat.id)", title: chat.label, symbol: "chat", detail: chat.cwd,
                        destination: .chat(chat.id), role: .chat(state)).withTip(chat.cwd)
        }
        func folder(_ project: Project, id: String) -> Self {
            .init(id: id, title: project.name, symbol: project.symbol,
                  detail: project.workspace,
                  destination: .project(project.id),
                  children: ordered.filter { $0.projectId == project.id }.map { row($0) },
                  role: .project)
        }
        let projectIDs = Set(projects.map(\.id))
        var result: [Self] = [
            .init(id: "new-session", title: String(localized: "New Task"), symbol: "newSession", destination: .newSession),
            .init(id: "overview", title: String(localized: "Projects"), symbol: "pullRequests", destination: .overview),
            .init(id: "automation", title: String(localized: "Automation"), symbol: "automation", destination: .automation)
        ]
        // Pinned lists across projects and has an order of its own: a drag inside one project
        // must not change the order used when sessions are pinned. A pinned project moves here
        // whole, folder and unpinned sessions, and trades places with the pinned sessions.
        let pinned = pins(projects: projects, sessions: sessions, order: order)
        if !pinned.isEmpty {
            result.append(label("label:pinned", String(localized: "Pinned")))
            result += pinned.map { pin in
                switch pin {
                case .project(let project): folder(project, id: "pin:\(project.id)")
                case .session(let session): row(session, pinned: true)
                }
            }
        }
        // With every project pinned, Projects has nothing under it and its heading goes too.
        let unpinned = projects.filter { !order.pinnedProjects.contains($0.id) }
        if !unpinned.isEmpty || projects.isEmpty { result.append(label("label:projects", String(localized: "Projects"))) }
        result += unpinned.map { folder($0, id: "project:\($0.id)") }
        // Sessions whose project was deleted stay, under a heading of their own: listed bare after the
        // projects they read as the last project's.
        let orphans = ordered.filter { !projectIDs.contains($0.projectId) }
        if !orphans.isEmpty {
            result.append(label("label:sessions", String(localized: "Sessions")))
            result += orphans.map { row($0) }
        }
        if !chats.isEmpty {
            result.append(label(chatsID, String(localized: "Chats")))
            result += chats.map(chatRow)
        }
        for section in remote { result += remoteSection(section) }
        return result
    }

    /// A paired Mac's heading and rows. Nothing in them is this Mac's: no row names a local path,
    /// so none offers Finder, and a session is not selectable, since its terminal is the other Mac's.
    static func remoteSection(_ section: SidebarRemoteSection) -> [Self] {
        let peer = section.peer
        let state: String? = switch peer.reach {
        case .online: nil
        case .connecting: String(localized: "Connecting")
        case .offline: String(localized: "Offline")
        case .revoked: String(localized: "Access removed")
        case .changed: String(localized: "Pair again")
        }
        var result = [Self(id: "label:remote:\(peer.id)", title: state.map { "\(peer.name) · \($0)" } ?? peer.name,
                           symbol: "", role: .label)]
        result += section.sessions.map { session in
            Self(id: "remote-session:\(peer.id):\(session.id)", title: session.label, symbol: "terminal",
                 role: .chat(SidebarChatStatus(cli: session.cli)))
                .withTip(String(localized: "Runs on \(peer.name): \(session.worktree)"))
        }
        result += section.chats.map { chat in
            let status = SidebarChatStatus(working: chat.working, needsInput: chat.needsInput, cli: chat.cli)
            return Self(id: "remote-chat:\(peer.id):\(chat.id)", title: chat.label, symbol: "chat",
                        destination: .remoteChat(peer: peer.id, thread: chat.id), role: .chat(status))
                .withTip(String(localized: "On \(peer.name), read only"))
        }
        return result
    }

    /// A row of the Pinned section: a session, or a project with its unpinned sessions.
    enum Pin: Identifiable {
        case project(Project), session(WorkspaceSession)
        var id: String {
            switch self {
            case .project(let project): project.id
            case .session(let session): session.id
            }
        }
    }

    /// The Pinned section in sidebar order: dragged order first, then pinned sessions as they
    /// come, then pinned projects as Projects lists them.
    static func pins(projects: [Project], sessions: [WorkspaceSession], order: SidebarOrder) -> [Pin] {
        let pins = displayOrder(sessions.filter(\.pinned), dragged: order.pinned).map(Pin.session)
            + displayOrder(projects, dragged: order.projects).filter { order.pinnedProjects.contains($0.id) }.map(Pin.project)
        let rank = Dictionary(order.pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return pins.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id] ?? Int.max, r = rank[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The Chats heading's id.
    static let chatsID = "label:chats"

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

