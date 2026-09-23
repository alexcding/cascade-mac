import SwiftUI

/// Every ticket assigned to the user, pushed over the Dashboard's home: the stage bar, a tag per
/// stage and one for urgent, then the sortable table with its customisable columns.
struct DashboardTicketsView: View {
    @Bindable var model: DashboardViewModel

    var body: some View {
        let rows = model.tickets.screenRows
        let counts = model.tickets.counts
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardPageHeader(caption: "\(model.tickets.tile.count) assigned to you, urgent first", title: "My tickets") {
                    DashboardRefreshButton(name: "tickets", id: "tickets", busy: model.tickets.loading, action: model.tickets.refresh)
                        .padding(.bottom, 6)
                }
                .padding(.top, 12).padding(.bottom, 24)
                if let error = model.navigation.error { warning(error) }
                if let error = model.tickets.error { warning(error) }
                if model.tickets.stages.total > 0 {
                    TicketStageBar(stages: model.tickets.stages) { model.tickets.filter = .stage($0) }
                }
                DashboardFilterTags(values: DashboardTicketsModel.Filter.allCases, selection: model.tickets.filter,
                                    title: \.title, count: { counts[$0] ?? 0 },
                                    id: { "dashboard-ticket-filter-\($0.id)" }) { model.tickets.filter = $0 }
                    .padding(.top, model.tickets.tile.count == 0 ? 0 : 24).padding(.bottom, 24)
                if rows.isEmpty {
                    Text(!model.tickets.available ? "Jira isn’t connected, so there are no tickets to show." : model.tickets.loading ? "Loading tickets…" : "No tickets match.")
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3).padding(.top, 12)
                } else {
                    DashboardTicketTable(rows: rows, opening: model.navigation.opening,
                        open: { model.open($0) }, openTab: { model.open($0, inTab: true) },
                        session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark)
                }
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
        }
        .accessibilityIdentifier("dashboard-tickets")
        .onDisappear(perform: model.cancelActions)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
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
