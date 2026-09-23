import Foundation
import Observation

/// The dashboard's Jira tickets: the load, and every list, count and tile built from it. Tickets
/// load apart from the PR snapshot, so a GitHub sync never re-queries Jira and a slow or
/// unconfigured Jira never holds the pull requests back.
@MainActor @Observable final class DashboardTicketsModel {
    /// Fires after a changed ticket list is published, so the owner can follow it.
    @ObservationIgnored var onChange: () -> Void = {}
    private(set) var retired = false

    private(set) var rows: [DashboardTicketRow] = []
    /// Each My Tickets tag's count over `rows`.
    private(set) var counts = DashboardTicketsModel.makeSummary([]).counts
    /// The home screen's short list; see `rankAttention`.
    private(set) var attention: [DashboardTicketRow] = []
    /// My Tickets' rows under `filter`, urgent first, each stamped with its linked pull request.
    private(set) var screenRows: [DashboardTicketRow] = []
    /// Start from an empty list's summary, so the tile reads "0 to do · …" before and without tickets.
    private(set) var tile = DashboardTicketsModel.makeSummary([]).tile
    private(set) var stages = DashboardTicketsModel.makeSummary([]).stages
    private(set) var error: String?
    private(set) var loading = false
    /// Mirrors the service, which is not observed, so the toolbar's Tickets tab appears the moment a
    /// Jira-capable service connects and goes when it is dropped.
    private(set) var available = false
    var filter: Filter = .all { didSet { if filter != oldValue { updateScreenRows() } } }
    /// The pull request each Jira key is linked to, from the PR snapshot. The short list skips work
    /// a listed pull request already stands for, and My Tickets shows the number.
    var linkedPRs: [String: String] = [:] {
        didSet {
            guard linkedPRs != oldValue else { return }
            updateAttention()
            updateScreenRows()
        }
    }

    /// How many tickets the home screen's short list shows.
    static let attentionLimit = 5

    @ObservationIgnored private var service: (any DashboardTicketService)? {
        didSet { if available != (service != nil) { available = service != nil } }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func connect(_ service: (any DashboardTicketService)?) {
        guard !retired else { return }
        cancel()
        self.service = service
        refresh()
    }

    func refresh() {
        guard !retired, let service, task == nil else { return }
        let generation = generation
        loading = true
        task = Task {
            defer { if self.generation == generation { task = nil; loading = false } }
            do {
                let rows = try await service.myTickets()
                try Task.checkCancellation()
                guard isCurrent(generation) else { return }
                if self.rows != rows {
                    let summary = await Self.summarize(rows)
                    guard isCurrent(generation) else { return }
                    self.rows = rows
                    if counts != summary.counts { counts = summary.counts }
                    if tile != summary.tile { tile = summary.tile }
                    if stages != summary.stages { stages = summary.stages }
                    updateAttention()
                    updateScreenRows()
                    onChange()
                }
                error = nil
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
        task?.cancel(); task = nil; loading = false
    }

    private func isCurrent(_ generation: UUID) -> Bool { !retired && self.generation == generation }

    private func updateAttention() {
        let value = Self.rankAttention(rows, linked: linkedPRs, limit: Self.attentionLimit)
        if attention != value { attention = value }
    }

    private func updateScreenRows() {
        let tagged = Self.stamp(rows.filter(filter.matches), linked: linkedPRs)
        let value = tagged.filter(\.urgent) + tagged.filter { !$0.urgent }
        if screenRows != value { screenRows = value }
    }
}

// MARK: - Derivation

extension DashboardTicketsModel {
    struct Summary: Sendable {
        var counts: [Filter: Int]
        var tile: Tile
        var stages: StageSummary
    }

    /// Everything the views read from the ticket list, worked out once per load off the main actor.
    nonisolated static func summarize(_ rows: [DashboardTicketRow]) async -> Summary { makeSummary(rows) }

    nonisolated static func makeSummary(_ rows: [DashboardTicketRow]) -> Summary {
        let counts = count(rows)
        let stages = TicketStage.allCases.map { StageCount(stage: $0, count: counts[.stage($0)] ?? 0) }
        return Summary(
            counts: counts,
            tile: Tile(count: rows.count, urgent: counts[.urgent] ?? 0,
                       footnote: stages.map { "\($0.count) \($0.stage.title.lowercased())" }.joined(separator: " · ")),
            stages: StageSummary(all: stages, live: stages.filter { $0.count > 0 }, total: rows.count))
    }

    /// Each My Tickets tag's count, in one pass.
    nonisolated static func count(_ rows: [DashboardTicketRow]) -> [Filter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: Filter.allCases.map { ($0, 0) })
        for row in rows {
            counts[.all, default: 0] += 1
            counts[.stage(row.stage), default: 0] += 1
            if row.urgent { counts[.urgent, default: 0] += 1 }
        }
        return counts
    }

    /// The home screen's short list, in `attentionRank` order and each group in Jira's own order.
    /// A ticket being worked on is left out once one of the listed pull requests names it: the
    /// pull request's row already stands for that work. Nothing else is padded in.
    nonisolated static func rankAttention(_ rows: [DashboardTicketRow], linked: [String: String], limit: Int) -> [DashboardTicketRow] {
        let ranked = rows.enumerated().compactMap { offset, row -> (rank: Int, offset: Int, row: DashboardTicketRow)? in
            guard let rank = row.attentionRank, !(rank == 2 && linked[row.ticket.key] != nil) else { return nil }
            return (rank, offset, row)
        }
        return Array(ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.prefix(limit).map(\.row))
    }

    /// The rows with their Pull Request column filled from the PR snapshot's links.
    nonisolated static func stamp(_ rows: [DashboardTicketRow], linked: [String: String]) -> [DashboardTicketRow] {
        rows.map { row in
            var row = row
            row.pullRequest = linked[row.ticket.key] ?? ""
            return row
        }
    }
}

// MARK: - Types

extension DashboardTicketsModel {
    /// The My Tickets screen's tags: every ticket, one workflow stage, or the urgent ones.
    enum Filter: Hashable, Identifiable, Sendable {
        case all, stage(TicketStage), urgent
        static let allCases: [Filter] = [.all] + TicketStage.allCases.map(Filter.stage) + [.urgent]
        var id: String {
            switch self {
            case .all: return "all"
            case .stage(let stage): return stage.rawValue
            case .urgent: return "urgent"
            }
        }
        var title: String {
            switch self {
            case .all: return "All"
            case .stage(let stage): return stage.title
            case .urgent: return "Urgent"
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

    /// The Tickets assigned tile.
    struct Tile: Equatable, Sendable {
        var count = 0
        var urgent = 0
        var footnote = ""
    }

    struct StageCount: Equatable, Identifiable, Sendable {
        let stage: TicketStage
        let count: Int
        var id: TicketStage { stage }
    }

    /// The tickets per stage: every stage for a legend, the non-empty ones for a bar.
    struct StageSummary: Equatable, Sendable {
        var all: [StageCount] = []
        var live: [StageCount] = []
        var total = 0
    }
}
