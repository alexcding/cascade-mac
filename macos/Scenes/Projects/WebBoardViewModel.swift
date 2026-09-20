import Foundation
import Observation

struct BoardTicketLink: Decodable, Equatable {
    let type: String
    let url: String
    let title: String
    let external: Bool

    static func parse(_ body: Any, source: URL?, expected: URL, mainFrame: Bool) -> Self? {
        guard mainFrame, source == expected, JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 8192,
              let link = try? JSONDecoder().decode(Self.self, from: data), link.type == "openTicket",
              SessionPage.parse(link.url)?.kind == "jira" else { return nil }
        return link
    }
}

struct BoardColumn: Decodable, Equatable, Sendable {
    let name: String
    var statusIds: [String] = []
    var statuses: [BoardStatus]?
}

struct BoardStatus: Decodable, Equatable, Sendable {
    let id: String
    let name: String
}

struct BoardSprint: Decodable, Equatable, Sendable {
    var name: String?
    var endDate: String?
}

struct BoardSnapshot: Decodable, Sendable {
    var items: [JiraTicket]
    var lastSynced: String?
    var error: String?
    var sprint: BoardSprint?
    var query: String?
    var columns: [BoardColumn]?
}

/// One drop target: a single workflow status inside a board column. `status` is the name acli
/// transitions into; an empty one (the "Other" bucket, or an id nothing names) is never a target.
struct BoardLane: Equatable, Identifiable {
    let status: String
    let statusId: String
    var tickets: [JiraTicket] = []
    var id: String { statusId.isEmpty ? "status:" + status : statusId }
}

/// A board column as Jira configures it: an ordered group of status lanes.
struct BoardGroup: Equatable, Identifiable {
    let id: Int
    let name: String
    var lanes: [BoardLane]
    var total: Int { lanes.reduce(0) { $0 + $1.tickets.count } }
    /// Single-status columns show no lane headers, even while dragging.
    var isGrouped: Bool { lanes.count > 1 }

    /// Workflow categories left to right, for boards with no column config. Blank or unknown
    /// categories sort alongside In Progress.
    private static let categoryRank = ["new": 0, "indeterminate": 1, "done": 2]

    /// Prefers the board's configured columns, each split into its status lanes (a "To Do" column
    /// holding "Ready for Dev" and "In Specification"). Tickets whose status no column claims
    /// collect in a trailing "Other" column. Without config, one column per status name, ordered by
    /// workflow category.
    static func build(_ tickets: [JiraTicket], columns config: [BoardColumn]?) -> [BoardGroup] {
        guard let config, !config.isEmpty else {
            var groups: [(category: String, lane: BoardLane)] = []
            for ticket in tickets {
                let name = ticket.status ?? ""
                if let index = groups.firstIndex(where: { $0.lane.status == name }) {
                    groups[index].lane.tickets.append(ticket)
                } else {
                    groups.append((ticket.statusCategory ?? "", BoardLane(status: name, statusId: ticket.statusId ?? "", tickets: [ticket])))
                }
            }
            return groups.sorted {
                let (left, right) = (categoryRank[$0.category] ?? 1, categoryRank[$1.category] ?? 1)
                return left != right ? left < right : $0.lane.status.localizedStandardCompare($1.lane.status) == .orderedAscending
            }.enumerated().map { BoardGroup(id: $0.offset, name: $0.element.lane.status.isEmpty ? "—" : $0.element.lane.status, lanes: [$0.element.lane]) }
        }
        var names: [String: String] = [:]
        for column in config { for status in column.statuses ?? [] where !status.name.isEmpty { names[status.id] = status.name } }
        for ticket in tickets {
            if let id = ticket.statusId, names[id] == nil, let status = ticket.status, !status.isEmpty { names[id] = status }
        }
        var groups = config.enumerated().map { index, column in
            BoardGroup(id: index, name: column.name, lanes: column.statusIds.map { BoardLane(status: names[$0] ?? "", statusId: $0) })
        }
        var other = BoardLane(status: "", statusId: "")
        for ticket in tickets {
            if let column = groups.firstIndex(where: { $0.lanes.contains { $0.statusId == ticket.statusId } }),
               let lane = groups[column].lanes.firstIndex(where: { $0.statusId == ticket.statusId }) {
                groups[column].lanes[lane].tickets.append(ticket)
            } else {
                other.tickets.append(ticket)
            }
        }
        if !other.tickets.isEmpty { groups.append(BoardGroup(id: groups.count, name: "Other", lanes: [other])) }
        return groups
    }
}

/// A transition shown before Jira confirms it. acli's search index can trail a transition by about
/// two minutes, so a refresh right after the move would otherwise put the card back.
struct PendingBoardMove: Equatable {
    let status: String
    let statusId: String
    let at: Date
    static let lifetime: TimeInterval = 300
}

protocol BoardService: Sendable {
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot
    func site() async throws -> JiraSite
    func settings() async throws -> [String: String]
    func saveFilter(_ value: String, projectID: String) async throws
    func saveQuery(_ value: String, projectID: String) async throws
    func transition(key: String, status: String) async throws
    func assign(key: String, assignee: String) async throws
}

struct APIBoardService: BoardService {
    let api: APIClient
    func snapshot(projectID: String, force: Bool) async throws -> BoardSnapshot {
        try await api.get(Routes.projectBoard(projectID) + (force ? "?refresh=1" : ""), timeout: force ? 130 : 30)
    }
    func site() async throws -> JiraSite { try await api.get(Routes.JIRA_SITE, timeout: 30) }
    func settings() async throws -> [String: String] { try await api.get(Routes.SETTINGS) }
    func saveFilter(_ value: String, projectID: String) async throws { try await api.setSetting("board_filter_" + projectID, value: value) }
    // The poller reads `board_query_<id>` from config and ANDs it into the board and Tickets JQL.
    func saveQuery(_ value: String, projectID: String) async throws {
        let _: OperationOK = try await api.request(Routes.CONFIG, method: "POST", body: ["board_query_" + projectID: value], timeout: 10)
    }
    func transition(key: String, status: String) async throws {
        let _: OperationOK = try await api.request(Routes.jiraKeyTransition(key), method: "POST", body: ["transition": status])
    }
    func assign(key: String, assignee: String) async throws {
        let _: OperationOK = try await api.request(Routes.jiraKeyAssign(key), method: "POST", body: ["assignee": assignee])
    }
}

@MainActor @Observable final class WebBoardViewModel {
    enum Action: Equatable { case openTicket(BoardTicketLink) }
    static let unassigned = "__unassigned__"
    static let unmappedDrop = "Can’t tell which status this column maps to — use the move menu."
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let navigation: PageActionViewModel
    private(set) var retired = false
    let projectID: String
    private(set) var snapshot: BoardSnapshot?
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var loading = false
    private(set) var busy: Set<String> = []
    private(set) var siteURL: URL?
    private(set) var account: JiraAccount?
    private(set) var pendingMoves: [String: PendingBoardMove] = [:]
    private(set) var draggingKey: String?
    /// New for every drag, so a watcher left over from the last drag of the same card can't end this one.
    private(set) var dragID: UUID?
    private(set) var dropTarget: String?
    var assigneeFilter = "" { didSet { if oldValue != assigneeFilter { persistFilter() } } }
    var queryDraft = ""
    /// Set by the view while the query field has focus, so a background refresh never clobbers a
    /// half-typed clause.
    @ObservationIgnored var queryEditing = false
    var appearance = AppAppearance.system
    var active = false { didSet { if active && !oldValue { refresh() } else if !active { cancelActions() } } }
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var service: any BoardService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queuedRefresh: Bool?
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var preferencesLoaded = false

    convenience init(projectID: String, api: APIClient, pageActions: any PageActionServing) {
        self.init(projectID: projectID, service: APIBoardService(api: api), pageActions: pageActions)
    }

    init(projectID: String, service: any BoardService, pageActions: any PageActionServing) {
        self.projectID = projectID
        self.service = service
        navigation = PageActionViewModel(service: pageActions)
    }

    /// Snapshot items with unconfirmed moves applied.
    var items: [JiraTicket] {
        (snapshot?.items ?? []).map { ticket in
            guard let move = pendingMoves[ticket.key] else { return ticket }
            var moved = ticket
            moved.status = move.status
            if !move.statusId.isEmpty { moved.statusId = move.statusId }
            return moved
        }
    }
    var tickets: [JiraTicket] {
        if assigneeFilter == Self.unassigned { return items.filter { ($0.assigneeId ?? "").isEmpty } }
        if !assigneeFilter.isEmpty { return items.filter { $0.assigneeId == assigneeFilter } }
        return items
    }
    var groups: [BoardGroup] { BoardGroup.build(tickets, columns: snapshot?.columns) }
    /// Every status a card can be moved to, in board order.
    var columns: [String] {
        var result: [String] = []
        for column in snapshot?.columns ?? [] {
            for id in column.statusIds {
                if let status = statusName(id: id), !result.contains(status) { result.append(status) }
            }
        }
        for status in (snapshot?.items ?? []).compactMap(\.status) where !status.isEmpty && !result.contains(status) { result.append(status) }
        return result
    }
    var assignees: [(id: String, name: String)] {
        var people: [String: String] = [:]
        for ticket in snapshot?.items ?? [] {
            if let id = ticket.assigneeId, !id.isEmpty { people[id] = ticket.assignee ?? id }
        }
        return people.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var showsUnassignedFilter: Bool {
        assigneeFilter == Self.unassigned || (snapshot?.items ?? []).contains { ($0.assigneeId ?? "").isEmpty }
    }
    var sprintTitle: String? {
        guard let name = snapshot?.sprint?.name, !name.isEmpty else { return nil }
        let days = snapshot?.sprint?.endDate.map { Self.businessDays(until: $0, from: now()) } ?? 0
        return days > 0 ? "\(name) · \(days)d left" : name
    }
    /// Why the board has no cards, once it has loaded; nil while it has some.
    var emptyMessage: String? {
        guard let snapshot, tickets.isEmpty else { return nil }
        if let error = snapshot.error, !error.isEmpty { return error }
        if !snapshot.items.isEmpty { return "No tickets match this filter." }
        if let query = snapshot.query, !query.isEmpty { return "No tickets match “\(query)” in the active sprint." }
        return "No active sprint, or no tickets in it."
    }
    func isMine(_ ticket: JiraTicket) -> Bool {
        guard let account else { return false }
        if let id = account.accountId, !id.isEmpty, ticket.assigneeId == id { return true }
        guard let email = account.email, !email.isEmpty, let assignee = ticket.assigneeEmail else { return false }
        return assignee.caseInsensitiveCompare(email) == .orderedSame
    }

    nonisolated static func businessDays(until end: String, from start: Date, calendar: Calendar = .current) -> Int {
        let formats: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]]
        let parsed = formats.lazy.compactMap { options -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            formatter.timeZone = calendar.timeZone // a date-only end date is a local day
            return formatter.date(from: end)
        }.first
        guard let parsed else { return 0 }
        let target = calendar.startOfDay(for: parsed)
        var day = calendar.startOfDay(for: start), count = 0
        while day < target, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
            if !calendar.isDateInWeekend(day) { count += 1 }
        }
        return count
    }

    func connect(api: APIClient) { connect(service: APIBoardService(api: api)) }
    func connect(service: any BoardService) {
        guard !retired else { return }
        generation = UUID(); task?.cancel(); task = nil; queuedRefresh = nil; self.service = service
        preferencesLoaded = false
        if active { refresh() }
    }
    func pause() { task?.cancel(); task = nil; queuedRefresh = nil; generation = UUID(); endDrag(); cancelActions() }
    // Retired is terminal: the coordinator has handed this model's screen to another instance, so
    // reactivating here would put a detached board back on the refresh timer and let its callbacks
    // fire again. Every other entry point already refuses; this one did not.
    func show(appearance: AppAppearance) {
        guard !retired else { return }
        self.appearance = appearance
        active = true
    }
    /// Overlapping requests collapse into one follow-up, and a refresh waits out a drag so the
    /// card being dragged never moves under the pointer.
    func refresh(force: Bool = false) {
        guard !retired, active else { return }
        guard task == nil, draggingKey == nil else { queuedRefresh = (queuedRefresh ?? false) || force; return }
        let generation = generation, service = service
        loading = true; error = nil
        task = Task {
            defer {
                if self.generation == generation {
                    loading = false; task = nil
                    if draggingKey == nil, let force = queuedRefresh { queuedRefresh = nil; refresh(force: force) }
                }
            }
            do {
                async let board = service.snapshot(projectID: projectID, force: force)
                async let site = service.site()
                let value = try await board
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                accept(value)
                if let location = try? await site, self.generation == generation {
                    siteURL = safeWebURL(location.baseUrl)
                    account = location.me
                }
                if !preferencesLoaded, let settings = try? await service.settings(), self.generation == generation {
                    assigneeFilter = settings["board_filter_" + projectID] ?? ""
                    preferencesLoaded = true
                }
            } catch { if !Task.isCancelled, self.generation == generation { self.error = error.localizedDescription } }
        }
    }
    func reload() { error = nil; refresh(force: true) }
    func cancelActions() { navigation.cancel() }
    func retire() { suspend(); retired = true; onAction = { _ in }; noticeTask?.cancel() }
    func suspend() { active = false; pause() }

    private func accept(_ value: BoardSnapshot) {
        let now = now()
        pendingMoves = pendingMoves.filter { key, move in
            guard now.timeIntervalSince(move.at) <= PendingBoardMove.lifetime else { return false }
            guard let ticket = value.items.first(where: { $0.key == key }) else { return true }
            return ticket.status != move.status && (move.statusId.isEmpty || ticket.statusId != move.statusId)
        }
        snapshot = value
        if !queryEditing { queryDraft = value.query ?? "" }
        if let message = value.error, !message.isEmpty { error = message }
    }
    private func statusName(id: String) -> String? {
        let named = snapshot?.columns?.lazy.compactMap { $0.statuses?.first(where: { $0.id == id })?.name }.first { !$0.isEmpty }
        let name = named ?? snapshot?.items.first(where: { $0.statusId == id })?.status
        return name?.isEmpty == false ? name : nil
    }
    private func statusID(named name: String) -> String {
        if let id = snapshot?.items.first(where: { $0.status == name })?.statusId, !id.isEmpty { return id }
        return snapshot?.columns?.lazy.compactMap { $0.statuses?.first(where: { $0.name == name })?.id }.first ?? ""
    }
    private func announce(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }

    private func persistFilter() {
        guard preferencesLoaded, !retired else { return }
        preferenceTask?.cancel()
        let value = assigneeFilter, service = service
        preferenceTask = Task {
            do { try await service.saveFilter(value, projectID: projectID) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    /// Saves the query box as the project's JQL clause, then re-syncs the board with it.
    func applyQuery() {
        let value = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retired, active, value != (snapshot?.query ?? "") else { return }
        queryDraft = value; error = nil
        let service = service, generation = generation
        Task {
            do {
                try await service.saveQuery(value, projectID: projectID)
                guard !retired, self.generation == generation else { return }
                announce(value.isEmpty ? "Jira filter cleared" : "Jira filter saved")
                refresh(force: true)
            } catch { if !retired, self.generation == generation { self.error = error.localizedDescription } }
        }
    }

    func beginDrag(_ ticket: JiraTicket) {
        guard !retired, active else { return }
        draggingKey = ticket.key; dragID = UUID(); dropTarget = nil
    }
    /// Ends the drag however it finished — dropped, cancelled, or released outside the board —
    /// and runs any refresh the drag held back. Given an `id`, only that drag is ended.
    func endDrag(_ id: UUID? = nil) {
        guard !retired, draggingKey != nil, id == nil || id == dragID else { return }
        draggingKey = nil; dragID = nil; dropTarget = nil
        if let force = queuedRefresh, task == nil { queuedRefresh = nil; refresh(force: force) }
    }
    func target(_ lane: BoardLane, _ targeted: Bool) {
        guard !retired, draggingKey != nil else { return }
        if targeted { dropTarget = lane.id } else if dropTarget == lane.id { dropTarget = nil }
    }
    @discardableResult func drop(_ key: String, on lane: BoardLane) -> Bool {
        defer { endDrag() }
        guard !retired, active, let ticket = items.first(where: { $0.key == key }) else { return false }
        if lane.tickets.contains(where: { $0.key == key }) { return true }
        guard !lane.status.isEmpty else { error = Self.unmappedDrop; return false }
        move(ticket, to: lane.status, statusId: lane.statusId)
        return true
    }

    /// Moves the card at once and transitions in the background; a failure puts it back.
    func move(_ ticket: JiraTicket, to status: String, statusId: String? = nil) {
        guard !retired, active, !status.isEmpty, ticket.status != status, !busy.contains(ticket.key) else { return }
        busy.insert(ticket.key); error = nil
        let move = PendingBoardMove(status: status, statusId: statusId.flatMap { $0.isEmpty ? nil : $0 } ?? statusID(named: status), at: now())
        pendingMoves[ticket.key] = move
        let service = service
        Task {
            defer { busy.remove(ticket.key) }
            do {
                try await service.transition(key: ticket.key, status: status)
                guard !retired else { return }
                announce("\(ticket.key) → \(status)")
                refresh(force: true)
            } catch {
                if pendingMoves[ticket.key] == move { pendingMoves[ticket.key] = nil }
                if !retired { self.error = error.localizedDescription }
            }
        }
    }
    func assign(_ ticket: JiraTicket, to assignee: String) {
        guard !retired, active, !busy.contains(ticket.key) else { return }
        busy.insert(ticket.key); error = nil
        let service = service
        Task {
            defer { busy.remove(ticket.key) }
            do { try await service.assign(key: ticket.key, assignee: assignee); refresh(force: true) }
            catch { self.error = error.localizedDescription }
        }
    }
    func open(_ ticket: JiraTicket) {
        guard let base = siteURL else { error = "Configure the Jira site before opening a ticket."; return }
        let url = base.appendingPathComponent("browse").appendingPathComponent(ticket.key).absoluteString
        onAction(.openTicket(.init(type: "openTicket", url: url, title: ticket.key, external: false)))
    }
    func perform(_ action: Action) {
        guard !retired, active else { return }
        switch action {
        case .openTicket(let link):
            // Every ticket opens in a Craft tab; `external` stays in the link's shape only.
            guard safeWebURL(link.url) != nil else { return }
            navigation.open(OpenPageRequest(url: link.url, kind: "jira", title: link.title))
        }
    }
    func request(_ link: BoardTicketLink) { perform(.openTicket(link)) }
}
