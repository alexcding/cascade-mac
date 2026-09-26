import SwiftUI

/// My Tickets, pushed over the Dashboard's home, in two views of the same work. List is every
/// ticket assigned to the user: the stage bar, a tag per stage and one for urgent, then the
/// sortable table. Board is one project's sprint board, the whole team's, to move and assign.
/// Either narrows to one project from the menu beside the view tags.
struct DashboardTicketsView: View {
    @Bindable var model: DashboardViewModel

    var body: some View {
        Group {
            if model.ticketsMode == .board { boardPage } else { listPage }
        }
        .accessibilityIdentifier("dashboard-tickets")
        .onDisappear(perform: model.cancelActions)
    }

    // MARK: List

    private var listPage: some View {
        let rows = model.tickets.screenRows
        let counts = model.tickets.pageCounts
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardPageHeader(caption: listCaption, title: String(localized: "My tickets")) {
                    DashboardRefreshButton(name: String(localized: "Tickets"), id: "tickets", busy: model.tickets.loading, action: model.tickets.refresh)
                        .padding(.bottom, 6)
                }
                .padding(.top, 12).padding(.bottom, 24)
                if let error = model.navigation.error { warning(error) }
                if let error = model.tickets.error { warning(error) }
                if model.tickets.pageStages.total > 0 {
                    TicketStageBar(stages: model.tickets.pageStages) { model.tickets.filter = .stage($0) }
                        .padding(.bottom, 24)
                }
                HStack(alignment: .top, spacing: 12) {
                    DashboardFilterTags(values: DashboardTicketsModel.Filter.allCases, selection: model.tickets.filter,
                                        title: \.title, count: { counts[$0] ?? 0 },
                                        id: { "dashboard-ticket-filter-\($0.id)" }) { model.tickets.filter = $0 }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    scope
                }
                .padding(.bottom, 24)
                if rows.isEmpty {
                    Text(!model.tickets.available ? String(localized: "Jira isn’t connected, so there are no tickets to show.") : model.tickets.loading ? String(localized: "Loading tickets…") : String(localized: "No tickets match."))
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3).padding(.top, 12)
                } else {
                    DashboardTicketTable(rows: rows, opening: model.navigation.opening,
                        open: { model.open($0) }, openTab: { model.open($0, inTab: true) },
                        session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark)
                }
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
        }
    }

    private var listCaption: String {
        let count = model.tickets.pageCounts[.all] ?? 0
        guard let project = model.tickets.project else { return String(localized: "\(count) assigned to you, urgent first") }
        return String(localized: "\(count) assigned to you in \(project.name), urgent first")
    }

    // MARK: Board

    /// The board fills the page rather than scrolling with it: each column scrolls on its own.
    private var boardPage: some View {
        let board = model.board.board
        return VStack(alignment: .leading, spacing: 0) {
            DashboardPageHeader(caption: boardCaption, title: String(localized: "Sprint board")) {
                if let board {
                    DashboardRefreshButton(name: String(localized: "Sprint board"), id: "board", busy: board.loading, action: board.reload)
                        .padding(.bottom, 6)
                }
            }
            .padding(.top, 12).padding(.bottom, 24)
            HStack(alignment: .center, spacing: 8) {
                if let board { DashboardBoardFilters(board: board) }
                Spacer(minLength: 12)
                scope
            }
            .padding(.bottom, 20)
            if let board {
                WebBoardView(model: board).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(!model.board.available && model.tickets.available
                     ? String(localized: "Add a Jira project key or saved JQL to a project to see its sprint board.")
                     : String(localized: "Jira isn’t connected, so there is no board to show."))
                    .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
                Spacer()
            }
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 20)
    }

    private var boardCaption: String {
        guard let project = model.board.project else { return String(localized: "The whole team’s sprint") }
        guard let sprint = model.board.board?.sprintTitle else { return String(localized: "\(project.name), the whole team") }
        return String(localized: "\(project.name) · \(sprint)")
    }

    // MARK: Scope

    /// List or Board, then the project, drawn as the page's tags.
    private var scope: some View {
        let boardMode = model.ticketsMode == .board
        let selected = boardMode ? model.board.project : model.tickets.project
        return HStack(spacing: 8) {
            ForEach(DashboardViewModel.TicketsMode.allCases) { mode in
                let active = model.ticketsMode == mode
                Button { model.setTicketsMode(mode) } label: {
                    DashboardTagLabel(title: mode.title, active: active)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dashboard-tickets-mode-\(mode.id)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            if !model.ticketProjects.isEmpty {
                Menu {
                    Picker("Project", selection: Binding(get: { selected?.id }, set: { model.selectTicketProject($0) })) {
                        // A board always shows one project; only the list can span them all.
                        if !boardMode {
                            Text("All Projects").tag(String?.none)
                            Divider()
                        }
                        ForEach(model.ticketProjects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    DashboardTagLabel(title: selected?.name ?? String(localized: "All Projects"), symbol: "chevron.down",
                                      active: !boardMode && selected != nil)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("dashboard-tickets-project")
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}

/// The board's own filters in the Dashboard's tag style: a JQL clause, applied on Return, and
/// whose cards to show.
private struct DashboardBoardFilters: View {
    let board: WebBoardViewModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .bold)).foregroundStyle(DashboardPalette.ink3)
                TextField("Filter, e.g. component = iOS", text: Bindable(board).queryDraft)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($queryFocused)
                    .onSubmit { board.applyQuery() }
                    .onChange(of: queryFocused) { _, focused in board.queryEditing = focused }
            }
            .padding(.horizontal, 10).frame(width: 240, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(queryFocused ? Color.primary.opacity(0.5) : DashboardPalette.buttonBorder, lineWidth: 1))
            .help("A JQL clause ANDed into the board (blank = everything). Return applies.")
            Menu {
                Picker("Assignee", selection: Binding(get: { board.assigneeFilter }, set: board.setAssigneeFilter)) {
                    Text("All assignees").tag("")
                    if board.showsUnassignedFilter { Text("Unassigned").tag(WebBoardViewModel.unassigned) }
                    ForEach(board.assignees, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                DashboardTagLabel(title: assigneeTitle, symbol: "chevron.down", active: !board.assigneeFilter.isEmpty)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("dashboard-board-assignee")
        }
    }

    private var assigneeTitle: String {
        switch board.assigneeFilter {
        case "": String(localized: "All assignees")
        case WebBoardViewModel.unassigned: String(localized: "Unassigned")
        case let id: board.assignees.first { $0.id == id }?.name ?? String(localized: "All assignees")
        }
    }
}

/// My Tickets' table: key and summary open the ticket; the row menu offers its session.
struct DashboardTicketTable: View {
    let rows: [DashboardTicketRow]
    let opening: String?
    let open: (DashboardTicketRow) -> Void
    let openTab: (DashboardTicketRow) -> Void
    let session: (DashboardTicketRow, SessionAgent?) -> Void
    let sessionMark: (DashboardTicketRow) -> PageSessionMark?
    @State private var sortOrder: [KeyPathComparator<DashboardTicketRow>] = []
    @State private var selection: DashboardTicketRow.ID?
    /// Right-click the header to show, hide or reorder; drag a divider to resize.
    @AppStorage("dashboard.columns.tickets") private var columns = Self.defaultColumns()

    /// The section opens on Ticket, Status, Type and Priority — what a ticket is triaged by.
    /// Everything else is opt-in through the header's right-click menu: Pull Request and Session
    /// are the dashboard's own cross-reference rather than the ticket's, Labels and Reporter are
    /// detail, and Project repeats the key's own prefix until more than one Jira project is
    /// tracked. Assignee is not offered at all: the section's JQL is `assignee = currentUser()`,
    /// so the column would read the same on every row.
    private static func defaultColumns() -> TableColumnCustomization<DashboardTicketRow> {
        var value = TableColumnCustomization<DashboardTicketRow>()
        for id in ["pr", "session", "labels", "reporter", "project"] { value[visibility: id] = .hidden }
        return value
    }
    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 28

    private var sorted: [DashboardTicketRow] {
        rows.map { row in
            var row = row
            row.sessionName = sessionMark(row)?.shortName ?? ""
            return row
        }.sorted(using: sortOrder)
    }
    private func row(_ id: DashboardTicketRow.ID?) -> DashboardTicketRow? { rows.first { $0.id == id } }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Ticket", value: \.title) { row in
                HStack(spacing: 8) {
                    Text(row.ticket.key).font(.system(size: 13.5)).foregroundStyle(DashboardPalette.link)
                    Button(action: { open(row) }) {
                        Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    }.buttonStyle(.plain).disabled(opening == row.url.absoluteString)
                        .accessibilityIdentifier("dashboard-ticket-\(row.ticket.key)")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 200, ideal: 420)
            .disabledCustomizationBehavior(.visibility)
            .customizationID("ticket")
            TableColumn("Status", value: \.status) { row in TicketStatusPill(row: row) }
                .width(min: 90, ideal: 150, max: 240).customizationID("status")
            TableColumn("Type", value: \.type) { row in
                Text(row.type).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.width(min: 56, ideal: 72, max: 150).customizationID("type")
            TableColumn("Priority", value: \.priority) { row in
                HStack(spacing: 6) {
                    TicketPriorityMark(level: row.level)
                    Text(row.priority).font(.system(size: 12, weight: row.urgent ? .semibold : .regular))
                        .foregroundStyle(row.urgent ? DashboardPalette.criticalText : Theme.textSecondary).lineLimit(1)
                }
            }.width(min: 60, ideal: 80, max: 150).customizationID("priority")
            TableColumn("Pull Request", value: \.pullRequest) { row in
                if !row.pullRequest.isEmpty {
                    Text(row.pullRequest).font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                        .foregroundStyle(Theme.accent).lineLimit(1)
                        .help("Open on this dashboard as \(row.pullRequest)")
                } else {
                    Text("—").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }.width(min: 72, ideal: 92, max: 170).customizationID("pr")
            TableColumn("Session", value: \.sessionName) { row in SessionCell(mark: sessionMark(row)) }
                .width(min: 72, ideal: 92, max: 180).customizationID("session")
            TableColumn("Labels", value: \.sortLabels) { row in JiraLabelList(labels: row.labels) }
                .width(min: 80, ideal: 150, max: 340).customizationID("labels")
            TableColumn("Reporter", value: \.reporter) { row in
                Text(row.reporter).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.width(min: 80, ideal: 110, max: 220).customizationID("reporter")
            TableColumn("Project", value: \.project) { row in
                Text(row.project).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.width(min: 60, ideal: 80, max: 160).customizationID("project")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .scrollDisabled(true)
        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(rows.count))
        .contextMenu(forSelectionType: DashboardTicketRow.ID.self) { ids in
            if let row = row(ids.first) {
                PageRowMenu(hasSession: sessionMark(row) != nil, open: { openTab(row) }, session: { session(row, $0) })
            }
        } primaryAction: { ids in
            if let row = row(ids.first) { open(row) }
        }
    }
}

/// A ticket's Jira labels. Jira labels carry no colour of their own, so unlike the pull request
/// Tags column there is no dot to draw; past two the rest go to the tooltip.
private struct JiraLabelList: View {
    let labels: [String]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.prefix(2), id: \.self) { label in
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
            }
            if labels.count > 2 {
                Text("+\(labels.count - 2)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary).fixedSize()
            }
        }.help(labels.joined(separator: ", "))
    }
}

/// The Session column: the agent's chip, or a dash for a page nothing is running on, so an empty
/// cell reads as "no session" rather than as a column that failed to draw.
private struct SessionCell: View {
    let mark: PageSessionMark?
    var body: some View {
        if let mark { AgentChip(mark: mark) } else {
            Text("—").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                .help("No session").accessibilityLabel("No session")
        }
    }
}
