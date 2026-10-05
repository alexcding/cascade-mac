import Foundation
import Observation

/// The dashboard's pull requests: the snapshot read, the forced sync, and every list and count
/// built from it. Derivation runs off the main actor once per snapshot; views only read.
@MainActor @Observable final class DashboardPullRequestsModel {
    /// Fires after a changed snapshot is published, so the owner can follow it.
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var retired = false

    private(set) var projects: [DashboardProject] = []
    /// Every open pull request the dashboard shows: the user's own, then the review orbit.
    private(set) var visibleRows: [DashboardRow] = []
    /// The user's own pull requests, newest first.
    private(set) var mine: [DashboardRow] = []
    /// Pull requests in the user's review orbit, newest first.
    private(set) var reviews: [DashboardRow] = []
    /// Everyone else's open pull requests outside the review orbit, newest first.
    private(set) var others: [DashboardRow] = []
    /// Each Pull Requests tag's count over the rows `author` and `project` leave.
    private(set) var counts: [Filter: Int] = [:]
    /// Every Jira key a shown pull request references, against that pull request's number. The
    /// lowest number wins when two PRs name one ticket, so the link does not flip between them as
    /// the snapshot reorders.
    private(set) var linkedPRs: [String: String] = [:]
    /// The Pull Requests tab's rows under `filter`, one group per project.
    private(set) var groups: [ProjectGroup] = []
    private(set) var warnings: [String] = []
    /// When the pull requests shown were last synced with GitHub: the oldest sync among the
    /// projects that have one, so the age said is never younger than any of what is shown. A
    /// project whose sync is failing says so itself and is left out, or its last success, weeks
    /// back, would be the age of everything.
    private(set) var synced: Date?
    /// GitHub is not answering the backend's syncs: what is shown is what was saved. Said once
    /// here, where each project would otherwise say it for itself. Read apart from the snapshot
    /// (`refreshUnreachable`), so a snapshot event still costs one read.
    private(set) var unreachable = false
    private(set) var loading = false
    /// A forced GitHub sync, apart from `loading`: a snapshot read finishing mid-sync must not
    /// re-enable the refresh button while the sync still runs.
    private(set) var syncing = false
    private(set) var updated: Date?
    private(set) var error: String?
    var filter: Filter = .all { didSet { if filter != oldValue { updateGroups() } } }
    /// Whose pull requests the Pull Requests tab lists.
    var author: Author = .mine { didSet { if author != oldValue { updateGroups() } } }
    /// The one project the Pull Requests tab lists, or nil for every project.
    var project: String? { didSet { if project != oldValue { updateGroups() } } }

    @ObservationIgnored private var service: (any DashboardService)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var unreachableTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    /// Whether a read waiting its turn is a look, which the backend may sync behind.
    @ObservationIgnored private var lookPending = false
    @ObservationIgnored private var generation = UUID()
    /// Orders snapshot reads: a read deriving off the main actor can finish after a later one, and
    /// must not overwrite what the later one published.
    @ObservationIgnored private var loadSequence = 0
    @ObservationIgnored private var publishedSequence = 0

    var connected: Bool { service != nil }

    func connect(_ service: (any DashboardService)?) {
        guard !retired else { return }
        cancel()
        self.service = service
        refresh(look: true)
        refreshUnreachable()
    }

    /// Asks which services the backend cannot reach: on connecting, on a full reload, and
    /// whenever the backend says that changed (an `upstream` event). The latest ask wins.
    func refreshUnreachable() {
        guard !retired, let service else { return }
        let generation = generation
        unreachableTask?.cancel()
        unreachableTask = Task {
            let down = ((try? await service.unreachable()) ?? []).contains("github")
            guard !Task.isCancelled, isCurrent(generation) else { return }
            if unreachable != down { unreachable = down }
        }
    }

    /// Reads the snapshot again. `quiet`: without the busy state, for a read nobody asked for
    /// by hand (a look every interval, a sync the backend reported), so the refresh buttons do
    /// not blink each time. `look`: someone is looking at the dashboard, so the backend may sync
    /// behind the read; a read made because the backend said a sync changed something is not a
    /// look, and must not be one, or each sync's report would start the next sync.
    func refresh(quiet: Bool = false, look: Bool = false) {
        guard !retired, let service else { return }
        refreshPending = true
        if look { lookPending = true }
        if !quiet { loading = true }
        guard refreshTask == nil else { return }
        let generation = generation
        refreshTask = Task {
            defer { if self.generation == generation { refreshTask = nil; loading = false } }
            while refreshPending && !Task.isCancelled && self.generation == generation {
                refreshPending = false
                let look = lookPending
                lookPending = false
                do {
                    try await load(from: service, look: look, generation: generation)
                } catch {
                    if !Task.isCancelled && self.generation == generation { self.error = error.localizedDescription }
                }
            }
        }
    }

    func sync() {
        guard !retired, let service, syncTask == nil else { return }
        let generation = generation
        syncing = true
        syncTask = Task {
            defer { if self.generation == generation { syncTask = nil; syncing = false } }
            do {
                try await service.syncPRs()
                try Task.checkCancellation()
                guard isCurrent(generation) else { return }
                try await load(from: service, look: false, generation: generation)
            } catch {
                if !Task.isCancelled && self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }

    func stop() async {
        for task in halt() { await task.value }
    }

    /// Cancels at once, before any suspension, and hands back the loads still winding down.
    func halt() -> [Task<Void, Never>] {
        let pending = [refreshTask, syncTask, unreachableTask].compactMap { $0 }
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
        refreshTask?.cancel(); refreshTask = nil; refreshPending = false; lookPending = false; loading = false
        syncTask?.cancel(); syncTask = nil; syncing = false
        unreachableTask?.cancel(); unreachableTask = nil
    }

    private func isCurrent(_ generation: UUID) -> Bool { !retired && self.generation == generation }

    /// Read the snapshot, build its display lists off the main actor, then publish them together
    /// before telling the owner.
    private func load(from service: any DashboardService, look: Bool, generation: UUID) async throws {
        loadSequence &+= 1
        let sequence = loadSequence
        let projects = try await (look ? service.look() : service.snapshot())
        try Task.checkCancellation()
        guard isCurrent(generation), sequence > publishedSequence else { return }
        guard self.projects != projects else { publishedSequence = sequence; updated = Date(); error = nil; return }
        let snapshot = await Self.derive(projects)
        try Task.checkCancellation()
        guard isCurrent(generation), sequence > publishedSequence else { return }
        publishedSequence = sequence
        defer { updated = Date(); error = nil }
        self.projects = projects
        if let project, !projects.contains(where: { $0.id == project }) { self.project = nil }
        if visibleRows != snapshot.visibleRows { visibleRows = snapshot.visibleRows }
        if mine != snapshot.mine { mine = snapshot.mine }
        if reviews != snapshot.reviews { reviews = snapshot.reviews }
        if others != snapshot.others { others = snapshot.others }
        if linkedPRs != snapshot.linkedPRs { linkedPRs = snapshot.linkedPRs }
        if warnings != snapshot.warnings { warnings = snapshot.warnings }
        if synced != snapshot.synced { synced = snapshot.synced }
        updateGroups()
        onChange()
    }

    /// How many open pull requests `author` has in the chosen project, or in every project.
    func count(_ author: Author) -> Int {
        rows(author).reduce(0) { $0 + (project == nil || $1.projectID == project ? 1 : 0) }
    }

    private func rows(_ author: Author) -> [DashboardRow] {
        switch author {
        case .mine: mine
        case .review: reviews
        case .others: others
        }
    }

    private func updateGroups() {
        let rows = self.rows(author).filter { project == nil || $0.projectID == project }
        let counts = Self.counts(rows)
        if self.counts != counts { self.counts = counts }
        let value = Self.group(rows, in: projects, by: filter)
        if groups != value { groups = value }
    }
}

// MARK: - Derivation

extension DashboardPullRequestsModel {
    struct Snapshot: Sendable {
        var visibleRows: [DashboardRow] = []
        var mine: [DashboardRow] = []
        var reviews: [DashboardRow] = []
        var others: [DashboardRow] = []
        var linkedPRs: [String: String] = [:]
        var warnings: [String] = []
        var synced: Date?
    }

    /// Everything the views read from a snapshot, worked out once per snapshot and away from the
    /// main actor rather than on every render.
    nonisolated static func derive(_ projects: [DashboardProject]) async -> Snapshot {
        var seen: Set<String> = []
        let rows = projects.flatMap { project in
            project.prs.compactMap { pr -> DashboardRow? in
                guard pr.error == nil, pr.state == "OPEN", let address = pr.url, let url = safeWebURL(address) else { return nil }
                let row = DashboardRow(projectID: project.id, projectName: project.name, pr: pr, url: url)
                return seen.insert(row.id).inserted ? row : nil
            }
        }
        var snapshot = Snapshot()
        snapshot.mine = rows.filter(\.isMine).sorted { $0.sortDate > $1.sortDate }
        snapshot.reviews = rows.filter { !$0.isMine && $0.inReviewGroup }.sorted { $0.sortDate > $1.sortDate }
        snapshot.others = rows.filter { !$0.isMine && !$0.inReviewGroup }.sorted { $0.sortDate > $1.sortDate }
        snapshot.visibleRows = rows.filter { $0.isMine || $0.inReviewGroup }
        var linked: [String: Int] = [:]
        for row in snapshot.visibleRows {
            guard let number = row.pr.number else { continue }
            // Keyed as `DashboardTicketRow.linkKey`: Jira keys and `OWNER/REPO#12`, uppercased.
            for key in row.pr.ticketKeys.map({ $0.uppercased() }) where number < linked[key] ?? .max { linked[key] = number }
        }
        snapshot.linkedPRs = linked.mapValues { "#\($0)" }
        snapshot.warnings = projects.flatMap { project -> [String] in
            var messages = project.prs.compactMap { $0.error.map { "\(project.name): \($0)" } }
            if let error = project.syncError { messages.insert("\(project.name): \(error)", at: 0) }
            // A first sync that failed says why above; it is not also being waited for.
            if project.lastSynced == nil, project.syncError == nil { messages.append(String(localized: "\(project.name): waiting for the first sync.")) }
            return messages
        }
        // The backend stamps to the millisecond; a stamp without them reads too.
        let precise = ISO8601DateFormatter(), plain = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        snapshot.synced = projects.compactMap { project -> Date? in
            guard !project.repo.isEmpty, project.syncError == nil, let stamp = project.lastSynced else { return nil }
            return precise.date(from: stamp) ?? plain.date(from: stamp)
        }.min()
        return snapshot
    }

    /// Each tag's count over `rows`.
    nonisolated static func counts(_ rows: [DashboardRow]) -> [Filter: Int] {
        Dictionary(uniqueKeysWithValues: Filter.allCases.map { filter in
            (filter, rows.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) })
        })
    }

    /// Pull requests under one tag, a group per project in the snapshot's project order.
    nonisolated static func group(_ rows: [DashboardRow], in projects: [DashboardProject], by filter: Filter) -> [ProjectGroup] {
        let rows = Dictionary(grouping: rows.filter(filter.matches), by: \.projectID)
        return projects.compactMap { project in rows[project.id].map { ProjectGroup(project: project, rows: $0) } }
    }
}

// MARK: - Types

extension DashboardPullRequestsModel {
    /// Whose pull requests the Pull Requests tab lists: the user's own, the ones in their review
    /// orbit, or everyone else's. Each open pull request is in exactly one.
    enum Author: String, CaseIterable, Identifiable, Sendable {
        case mine, review, others
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mine: String(localized: "Mine")
            case .review: String(localized: "To review")
            case .others: String(localized: "Others")
            }
        }
    }

    /// The Pull Requests tab's tags, each a check state or review state.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, failing, running, changesRequested, approved, drafts
        var id: String { rawValue }
        /// The filters the page offers: what needs someone. Another one, picked by a link, shows
        /// beside them while it is the current one, so it can be seen and left.
        static let critical: [Filter] = [.all, .failing, .changesRequested]
        static func shown(with current: Filter) -> [Filter] { critical.contains(current) ? critical : critical + [current] }
        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .failing: return String(localized: "Failing")
            case .running: return String(localized: "Running")
            case .changesRequested: return String(localized: "Changes requested")
            case .approved: return String(localized: "Approved")
            case .drafts: return String(localized: "Drafts")
            }
        }
        func matches(_ row: DashboardRow) -> Bool {
            switch self {
            case .all: return true
            case .failing: return row.checks == .failing
            case .running: return row.checks == .running
            case .changesRequested: return row.pr.reviewDecision == "CHANGES_REQUESTED"
            case .approved: return row.pr.reviewDecision == "APPROVED"
            case .drafts: return row.pr.isDraft == true
            }
        }
    }

    struct ProjectGroup: Equatable, Identifiable, Sendable {
        let project: DashboardProject
        let rows: [DashboardRow]
        var id: String { project.id }
    }
}
