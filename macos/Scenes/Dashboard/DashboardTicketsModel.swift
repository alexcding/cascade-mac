import Foundation
import Observation

/// The dashboard's Jira tickets: the load, and every list and count built from it. Tickets
/// load apart from the PR snapshot, so a GitHub sync never re-queries Jira and a slow or
/// unconfigured Jira never holds the pull requests back.
@MainActor @Observable final class DashboardTicketsModel {
    /// Fires after a changed ticket list is published, so the owner can follow it.
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var retired = false

    /// The user's tickets in the tracked projects: one no project claims is left out.
    private(set) var rows: [DashboardTicketRow] = []
    /// Open issues in the tracked repos that are someone else's or no one's: the Tickets tab's Others.
    private(set) var others: [DashboardTicketRow] = []
    /// Whose tickets the Tickets tab lists.
    var author: Author = .mine { didSet { if author != oldValue { updateScreenRows() } } }
    /// Tracked projects, from the dashboard snapshot; `rows` follows them.
    var projects: [DashboardProject] = [] {
        didSet { if projects != oldValue { publish(Self.split(Self.tracked(loaded, in: projects))) } }
    }
    /// Everything Jira returned, before `projects` narrows it.
    @ObservationIgnored private var loaded: [DashboardTicketRow] = []
    /// Whether Jira has returned no tickets at all, as opposed to none the tracked projects claim.
    var fetchedNothing: Bool { loaded.isEmpty }
    /// The Tickets tab's rows under `filter`, urgent first, each stamped with its linked pull request.
    private(set) var screenRows: [DashboardTicketRow] = []
    private(set) var error: String?
    private(set) var loading = false
    /// Mirrors the service, which is not observed, so the Tickets tab's content appears the moment a
    /// Jira-capable service connects and goes when it is dropped.
    private(set) var available = false
    var filter: Filter = .all { didSet { if filter != oldValue { updateScreenRows() } } }
    /// The one project the Tickets tab lists, or nil for every project. A ticket belongs to the project
    /// whose Jira key starts its own key.
    var project: DashboardProject? { didSet { if project != oldValue { updateScreenRows() } } }
    /// The Tickets tab's tag counts over the rows `project` leaves.
    private(set) var pageCounts = DashboardTicketsModel.count([])
    /// The pull request each Jira key is linked to, from the PR snapshot; the Tickets tab shows the number.
    var linkedPRs: [String: String] = [:] {
        didSet {
            guard linkedPRs != oldValue else { return }
            updateScreenRows()
        }
    }

    @ObservationIgnored private var service: (any DashboardTicketService)? {
        didSet { if available != (service != nil) { available = service != nil } }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A read asked for while one was in flight, as the most that was asked of it: run when
    /// that one ends, so the answer the backend just reported is not missed.
    @ObservationIgnored private var queued: TicketRead?
    @ObservationIgnored private var generation = UUID()

    func connect(_ service: (any DashboardTicketService)?) {
        guard !retired else { return }
        cancel()
        self.service = service
        refresh()
    }

    /// Reads My Tickets again, saying why (`TicketRead`): for someone looking unless told
    /// otherwise, which shows what the backend stored and lets it search again behind that.
    func refresh(_ read: TicketRead = .look) {
        guard !retired, let service else { return }
        guard task == nil else { queued = max(queued ?? .echo, read); return }
        let generation = generation
        // An echo is nobody's refresh: the buttons stay as they are.
        if read != .echo { loading = true }
        task = Task {
            defer {
                if self.generation == generation {
                    task = nil; loading = false
                    if let read = queued { queued = nil; refresh(read) }
                }
            }
            do {
                let (loaded, warning) = try await service.myTicketsReport(read)
                try Task.checkCancellation()
                guard isCurrent(generation) else { return }
                self.loaded = loaded
                let tracked = Self.tracked(loaded, in: projects)
                let split = Self.split(tracked)
                publish(split)
                // One source failing while the other loaded still says so beside the rows.
                error = warning
            } catch {
                if !Task.isCancelled && self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }

    func stop() async { await halt()?.value }

    /// Cancels at once, before any suspension, and hands back the load still winding down.
    func halt() -> Task<Void, Never>? {
        let pending = task
        cancel()
        service = nil
        return pending
    }

    func retire() {
        retired = true
        onChange = {}
        service = nil
        cancel()
    }

    private func cancel() {
        generation = UUID()
        task?.cancel(); task = nil; queued = nil; loading = false
    }

    private func isCurrent(_ generation: UUID) -> Bool { !retired && self.generation == generation }

    /// Publishes the tracked tickets, split into the user's and the others.
    private func publish(_ split: (mine: [DashboardTicketRow], others: [DashboardTicketRow])) {
        let (rows, others) = split
        guard !retired, self.rows != rows || self.others != others else { return }
        self.rows = rows
        self.others = others
        updateScreenRows()
        onChange()
    }

    /// How many tickets `author` has in the project the Tickets tab is narrowed to.
    func count(_ author: Author) -> Int { scoped(author).count }

    /// `author`'s tickets in the project the Tickets tab is narrowed to.
    private func scoped(_ author: Author) -> [DashboardTicketRow] {
        let rows = author == .mine ? rows : others
        return project.map { project in rows.filter { project.owns($0.ticket) } } ?? rows
    }

    private func updateScreenRows() {
        let scoped = scoped(author)
        let counts = Self.count(scoped)
        if pageCounts != counts { pageCounts = counts }
        let tagged = Self.stamp(scoped.filter(filter.matches), linked: linkedPRs)
        let value = tagged.filter(\.urgent) + tagged.filter { !$0.urgent }
        if screenRows != value { screenRows = value }
    }
}

// MARK: - Derivation

extension DashboardTicketsModel {
    /// Each Tickets tab tag's count, in one pass.
    nonisolated static func count(_ rows: [DashboardTicketRow]) -> [Filter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: Filter.allCases.map { ($0, 0) })
        for row in rows {
            counts[.all, default: 0] += 1
            counts[.stage(row.stage), default: 0] += 1
            if row.urgent { counts[.urgent, default: 0] += 1 }
        }
        return counts
    }

    /// The user's tickets and everyone else's, in their order.
    nonisolated static func split(_ rows: [DashboardTicketRow]) -> (mine: [DashboardTicketRow], others: [DashboardTicketRow]) {
        (rows.filter(\.ticket.isMine), rows.filter { !$0.ticket.isMine })
    }

    /// The tickets some tracked project claims: by Jira key, or an issue by its repo.
    nonisolated static func tracked(_ rows: [DashboardTicketRow], in projects: [DashboardProject]) -> [DashboardTicketRow] {
        rows.filter { row in projects.contains { $0.owns(row.ticket) } }
    }

    /// The rows with their Pull Request column filled from the PR snapshot's links.
    nonisolated static func stamp(_ rows: [DashboardTicketRow], linked: [String: String]) -> [DashboardTicketRow] {
        rows.map { row in
            var row = row
            row.pullRequest = linked[row.linkKey] ?? ""
            return row
        }
    }
}

// MARK: - Types

extension DashboardTicketsModel {
    /// Whose tickets the Tickets tab lists, as the Pull Requests tab has it: the user's own — every
    /// Jira ticket assigned to them and the issues they are an assignee of — or everyone else's
    /// open issues, unassigned ones included.
    enum Author: String, CaseIterable, Identifiable, Sendable {
        case mine, others
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mine: String(localized: "Mine")
            case .others: String(localized: "Others")
            }
        }
    }

    /// The Tickets tab's tags: every ticket, one workflow stage, or the urgent ones.
    enum Filter: Hashable, Identifiable, Sendable {
        case all, stage(TicketStage), urgent
        static let allCases: [Filter] = [.all] + TicketStage.allCases.map(Filter.stage) + [.urgent]
        /// The filters the page offers: what needs someone. Another one, picked by a link, shows
        /// beside them while it is the current one, so it can be seen and left.
        static let critical: [Filter] = [.all, .stage(.blocked), .urgent]
        static func shown(with current: Filter) -> [Filter] { critical.contains(current) ? critical : critical + [current] }
        var id: String {
            switch self {
            case .all: return "all"
            case .stage(let stage): return stage.rawValue
            case .urgent: return "urgent"
            }
        }
        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .stage(let stage): return stage.title
            case .urgent: return String(localized: "Urgent")
            }
        }
        func matches(_ row: DashboardTicketRow) -> Bool {
            switch self {
            case .all: return true
            case .stage(let stage): return row.stage == stage
            case .urgent: return row.urgent
            }
        }
    }
}
