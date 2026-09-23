import AppKit
import Observation

/// The dashboard's pull requests: the snapshot read, the forced sync, and every list, count and
/// tile built from it. Derivation runs off the main actor once per snapshot; views only read.
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
    /// Each Pull Requests tag's count over `mine`.
    private(set) var counts: [Filter: Int] = [:]
    /// Every Jira key a shown pull request references, against that pull request's number. The
    /// lowest number wins when two PRs name one ticket, so the link does not flip between them as
    /// the snapshot reorders.
    private(set) var linkedPRs: [String: String] = [:]
    /// The Pull Requests tab's rows under `filter`, one group per project.
    private(set) var groups: [ProjectGroup] = []
    private(set) var tile = Tile()
    private(set) var reviewTile = ReviewTile()
    /// The review tile authors' GitHub avatars, by login, as `SidebarAvatars` finishes fetching
    /// them; a login with none yet shows its initials.
    private(set) var avatars: [String: NSImage] = [:]
    private(set) var warnings: [String] = []
    private(set) var loading = false
    /// A forced GitHub sync, apart from `loading`: a snapshot read finishing mid-sync must not
    /// re-enable the refresh button while the sync still runs.
    private(set) var syncing = false
    private(set) var updated: Date?
    private(set) var error: String?
    var filter: Filter = .all { didSet { if filter != oldValue { updateGroups() } } }

    @ObservationIgnored private var service: (any DashboardService)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var generation = UUID()
    /// Orders snapshot reads: a read deriving off the main actor can finish after a later one, and
    /// must not overwrite what the later one published.
    @ObservationIgnored private var loadSequence = 0
    @ObservationIgnored private var publishedSequence = 0
    @ObservationIgnored private var avatarObserver: NSObjectProtocol?

    init() {
        avatarObserver = NotificationCenter.default.addObserver(forName: SidebarAvatars.loaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAvatars() }
        }
    }

    var connected: Bool { service != nil }

    func connect(_ service: (any DashboardService)?) {
        guard !retired else { return }
        cancel()
        self.service = service
        refresh()
    }

    func refresh() {
        guard !retired, let service else { return }
        refreshPending = true
        guard refreshTask == nil else { return }
        let generation = generation
        loading = true
        refreshTask = Task {
            defer { if self.generation == generation { refreshTask = nil; loading = false } }
            while refreshPending && !Task.isCancelled && self.generation == generation {
                refreshPending = false
                do {
                    try await load(from: service, generation: generation)
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
                try await load(from: service, generation: generation)
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
        let pending = [refreshTask, syncTask].compactMap { $0 }
        cancel()
        service = nil
        return pending
    }

    func retire() {
        retired = true
        onChange = {}
        if let avatarObserver { NotificationCenter.default.removeObserver(avatarObserver) }
        avatarObserver = nil
        service = nil
        cancel()
    }

    private func cancel() {
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil; refreshPending = false; loading = false
        syncTask?.cancel(); syncTask = nil; syncing = false
    }

    private func isCurrent(_ generation: UUID) -> Bool { !retired && self.generation == generation }

    /// Read the snapshot, build its display lists off the main actor, then publish them together
    /// before telling the owner.
    private func load(from service: any DashboardService, generation: UUID) async throws {
        loadSequence &+= 1
        let sequence = loadSequence
        let projects = try await service.snapshot()
        try Task.checkCancellation()
        guard isCurrent(generation), sequence > publishedSequence else { return }
        guard self.projects != projects else { publishedSequence = sequence; updated = Date(); error = nil; return }
        let snapshot = await Self.derive(projects)
        try Task.checkCancellation()
        guard isCurrent(generation), sequence > publishedSequence else { return }
        publishedSequence = sequence
        defer { updated = Date(); error = nil }
        self.projects = projects
        if visibleRows != snapshot.visibleRows { visibleRows = snapshot.visibleRows }
        if mine != snapshot.mine { mine = snapshot.mine }
        if reviews != snapshot.reviews { reviews = snapshot.reviews }
        if counts != snapshot.counts { counts = snapshot.counts }
        if linkedPRs != snapshot.linkedPRs { linkedPRs = snapshot.linkedPRs }
        if tile != snapshot.tile { tile = snapshot.tile }
        if reviewTile != snapshot.reviewTile { reviewTile = snapshot.reviewTile }
        // Every snapshot, not only a changed tile: a fetch that failed may retry after a minute.
        updateAvatars()
        if warnings != snapshot.warnings { warnings = snapshot.warnings }
        updateGroups()
        onChange()
    }

    /// Asks the shared cache for each author's face; one still fetching arrives later through
    /// `SidebarAvatars.loaded`, which calls this again.
    private func updateAvatars() {
        guard !retired else { return }
        var value: [String: NSImage] = [:]
        for login in reviewTile.authors {
            if let image = SidebarAvatars.image(login: login, frozen: nil) { value[login] = image }
        }
        if avatars != value { avatars = value }
    }

    private func updateGroups() {
        let value = Self.group(mine, in: projects, by: filter)
        if groups != value { groups = value }
    }
}

// MARK: - Derivation

extension DashboardPullRequestsModel {
    struct Snapshot: Sendable {
        var visibleRows: [DashboardRow] = []
        var mine: [DashboardRow] = []
        var reviews: [DashboardRow] = []
        var counts: [Filter: Int] = [:]
        var linkedPRs: [String: String] = [:]
        var tile = Tile()
        var reviewTile = ReviewTile()
        var warnings: [String] = []
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
        snapshot.visibleRows = rows.filter { $0.isMine || $0.inReviewGroup }
        snapshot.counts = Dictionary(uniqueKeysWithValues: Filter.allCases.map { filter in
            (filter, snapshot.mine.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) })
        })
        var linked: [String: Int] = [:]
        for row in snapshot.visibleRows {
            guard let number = row.pr.number else { continue }
            for key in row.pr.jiraKeys ?? [] where number < linked[key] ?? .max { linked[key] = number }
        }
        snapshot.linkedPRs = linked.mapValues { "#\($0)" }
        snapshot.tile = Tile(mine: snapshot.mine, counts: snapshot.counts)
        snapshot.reviewTile = ReviewTile(reviews: snapshot.reviews)
        snapshot.warnings = projects.flatMap { project -> [String] in
            var messages = project.prs.compactMap { $0.error.map { "\(project.name): \($0)" } }
            if let error = project.syncError { messages.insert("\(project.name): \(error)", at: 0) }
            if project.lastSynced == nil { messages.append("\(project.name): waiting for the first sync.") }
            return messages
        }
        return snapshot
    }

    /// The user's pull requests under one tag, a group per project in the snapshot's project order.
    nonisolated static func group(_ rows: [DashboardRow], in projects: [DashboardProject], by filter: Filter) -> [ProjectGroup] {
        let rows = Dictionary(grouping: rows.filter(filter.matches), by: \.projectID)
        return projects.compactMap { project in rows[project.id].map { ProjectGroup(project: project, rows: $0) } }
    }
}

// MARK: - Types

extension DashboardPullRequestsModel {
    /// The Pull Requests tab's tags, each a check state or review state of the user's own.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, failing, running, changesRequested, approved, drafts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .failing: return "Failing"
            case .running: return "Running"
            case .changesRequested: return "Changes requested"
            case .approved: return "Approved"
            case .drafts: return "Drafts"
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

    /// The Open pull requests tile.
    struct Tile: Equatable, Sendable {
        var count = 0
        var failing = 0
        var footnote = "0 drafts · 0 approved"
        /// Up to `dotLimit` rows for the check-state dot matrix, failing first so a cut never hides
        /// one, then running, unknown and passing.
        var dots: [DashboardRow] = []
        /// Two rows of ten, the matrix's size in the tile.
        static let dotLimit = 20

        init() {}
        init(mine: [DashboardRow], counts: [Filter: Int]) {
            let drafts = counts[.drafts] ?? 0
            count = mine.count
            failing = counts[.failing] ?? 0
            footnote = "\(drafts) draft\(drafts == 1 ? "" : "s") · \(counts[.approved] ?? 0) approved"
            dots = Array(mine.sorted { Self.rank($0.checks) < Self.rank($1.checks) }.prefix(Self.dotLimit))
        }
        private static func rank(_ checks: DashboardRow.Checks) -> Int {
            switch checks { case .failing: 0; case .running: 1; case .unknown: 2; case .passing: 3 }
        }
    }

    /// The Waiting on you tile.
    struct ReviewTile: Equatable, Sendable {
        var count = 0
        /// The oldest waiting review's age, `3d`, or nil with none waiting.
        var oldestAge: String?
        var footnote = "No review requests"
        /// The first three distinct authors, in list order.
        var authors: [String] = []

        init() {}
        init(reviews: [DashboardRow]) {
            count = reviews.count
            // `reviews` is newest first, so the longest wait is the last one with a date.
            oldestAge = reviews.last(where: { $0.created != nil })?.ageLabel
            let repos = Set(reviews.map { $0.pr.repo ?? $0.projectName }).count
            if !reviews.isEmpty { footnote = "across \(repos) repo\(repos == 1 ? "" : "s")" }
            for login in reviews.map(\.author) where !login.isEmpty && !authors.contains(login) {
                authors.append(login)
                if authors.count == 3 { break }
            }
        }
    }
}
