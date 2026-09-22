import Foundation
import SwiftUI

struct DashboardView: View {
    @Bindable var model: DashboardViewModel
    let shell: ShellStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.padding(.top, 8).padding(.bottom, 30)
                if let error = model.error { warning(error, retry: true) }
                if let error = model.navigation.error { warning(error) }
                ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, value in warning(value) }
                if model.updated == nil {
                    Text(model.loading ? "Loading pull requests…" : "Connect to load pull requests.").foregroundStyle(.secondary)
                } else if model.projects.isEmpty {
                    noProjects
                } else {
                    filterBar.padding(.bottom, 24)
                    results
                }
            }.padding(.bottom, 28)
        }
        .accessibilityIdentifier("native-dashboard")
        .task { await shell.watchUsage() }
        .onDisappear(perform: model.cancelActions)
    }

    private var noProjects: some View {
        VStack(spacing: 5) {
            Image(systemName: "folder").imageScale(.large).foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                .padding(.bottom, 9)
                .accessibilityHidden(true)
            Text("No projects yet").font(Theme.Typography.emptyTitle).foregroundStyle(Theme.textSecondary)
            Text("Add one with New Project in the sidebar to track its pull requests.")
                .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 11.5, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(.tertiary)
                Text(greeting).font(.system(size: 30, weight: .semibold)).tracking(-0.7)
            }
            Spacer(minLength: 16)
            DashboardUsageFigures(shell: shell).layoutPriority(1)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let value = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return NSFullUserName().split(separator: " ").first.map { "\(value), \($0)" } ?? value
    }

    /// Search plus the two segments. The segments read as underlined tabs rather than a filled
    /// control, so the surface keeps a single background.
    private var filterBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            searchField.frame(maxWidth: 340)
            HStack(spacing: 16) {
                ForEach(DashboardViewModel.Filter.allCases) { value in filterTab(value) }
            }
            Spacer(minLength: 8)
            if let updated = model.updated { syncedLabel(updated) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            TextField("Filter by title, repo, branch or key", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .accessibilityIdentifier("dashboard-filter")
            if !model.query.isEmpty {
                Button(action: model.clearFilter) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
    }

    private func filterTab(_ value: DashboardViewModel.Filter) -> some View {
        let active = model.filter == value
        return Button { model.filter = value } label: {
            Text(value.title)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.primary : Theme.textSecondary)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(active ? Color.primary : .clear).frame(height: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard-filter-\(value.rawValue)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func syncedLabel(_ updated: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text("Synced \(Self.age(of: updated, at: context.date)) ago")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize()
        }
    }

    private static func age(of date: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    /// The three sections, against the filtered lists. A section with no rows is dropped while a
    /// filter is on — its own empty line would otherwise read as "you have none", not "none match".
    /// Empty with no filter set is not the same state: a repository with no open pull requests
    /// gets the My Pull Requests section's own line, never an offer to clear a filter nobody set.
    @ViewBuilder private var results: some View {
        let mine = model.visibleMine, reviews = model.visibleReviews, tickets = model.visibleTickets
        let ticketError = model.ticketsAvailable && model.ticketsError != nil && !model.filtering
        if model.filtering && mine.isEmpty && reviews.isEmpty && tickets.isEmpty {
            noMatches
        } else {
            if !mine.isEmpty || !model.filtering {
                section("GitHub · My Pull Requests", rows: mine, empty: "No open PRs you authored.", kind: .mine)
            }
            // Review and Jira sections appear only with rows, so a project without Jira keys adds nothing.
            if !reviews.isEmpty { section("Review Requested", rows: reviews, empty: nil, kind: .review) }
            if !tickets.isEmpty || ticketError { ticketSection(tickets) }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 5) {
            Text("Nothing matches this filter").font(Theme.Typography.emptyTitle).foregroundStyle(Theme.textSecondary)
            Button("Clear the filter", action: model.clearFilter).buttonStyle(.link).font(Theme.Typography.emptyHint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    /// `empty` is shown only by a section that renders with no rows; a gated section passes nil.
    private func section(_ title: String, rows: [DashboardRow], empty: String?,
                         kind: DashboardTable.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, count: rows.count)
            Divider().padding(.bottom, rows.isEmpty ? 14 : 0)
            if rows.isEmpty { Text(empty ?? "").font(.system(size: 13)).foregroundStyle(Theme.textTertiary) }
            else {
                DashboardTable(rows: rows, opening: model.navigation.opening,
                    open: { model.open($0) }, openTab: { model.open($0, inTab: true) },
                    session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark,
                    kind: kind)
            }
        }.padding(.bottom, 36)
    }

    private func ticketSection(_ tickets: [DashboardTicketRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Jira · My Tickets", count: tickets.count)
            Divider().padding(.bottom, tickets.isEmpty ? 14 : 0)
            // Shown only with rows or an error, so the only empty state left is the error.
            if tickets.isEmpty {
                Text(model.ticketsError ?? "").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else {
                DashboardTicketTable(rows: tickets, opening: model.navigation.opening,
                    open: { model.open($0) }, openTab: { model.open($0, inTab: true) },
                    session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark,
                    linkedPRs: model.linkedPRs)
            }
        }.padding(.bottom, 36)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 9) {
            Text(title).font(.system(size: 15, weight: .semibold)).tracking(-0.2)
            Text("\(count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 1.5)
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
        }.padding(.bottom, 10)
    }

    private func warning(_ text: String, retry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill"); Spacer()
            if retry { Button("Retry", action: model.refresh) }
        }.font(.callout).foregroundStyle(.orange).padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}

/// The usage agent's remaining windows, drawn beside the dashboard greeting.
struct DashboardUsageFigures: View {
    let shell: ShellStore
    var body: some View {
        let limits = shell.usageAgent == "codex" ? shell.usage?.codexLimits : shell.usage?.limits
        if shell.usageLoading && limits == nil { ProgressView().controlSize(.small) }
        else if let limits {
            HStack(spacing: 10) {
                if let session = limits.session { UsageFigure(title: "Session", window: session, tint: tint) }
                if let weekly = limits.weekly { UsageFigure(title: "Weekly", window: weekly, tint: tint) }
                ForEach(Array((limits.scoped ?? []).enumerated()), id: \.offset) { _, value in UsageFigure(title: value.label ?? "Model", window: value, tint: tint) }
            }
        }
    }
    private var tint: Color { Theme.agentTint(shell.usageAgent) }
}

private struct UsageFigure: View {
    let title: String; let window: UsageSnapshot.Window; let tint: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: 2.5)
                    Circle().trim(from: 0, to: window.remaining / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                }.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(window.remaining.rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(resetLabel(now: context.date)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                }
            }.fixedSize().padding(.leading, 11).padding(.trailing, 15).padding(.vertical, 8)
                .background(.quaternary.opacity(0.38), in: Capsule())
        }
    }
    private func resetLabel(now: Date) -> String {
        guard let raw = window.resetsAt, let reset = backendTimestamp(raw) else { return title }
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let value = minutes >= 1_440 ? "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" : minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
        return "\(title) · \(value)"
    }
}

/// One native table per dashboard section. Sorting is per table; single-clicking the title or
/// double-clicking a row opens the pull request, and the row menu offers its session.
struct DashboardTable: View {
    let rows: [DashboardRow]
    let opening: String?
    let open: (DashboardRow) -> Void
    /// The menu's Open in Tab: a tab behind this screen, never the row's session.
    let openTab: (DashboardRow) -> Void
    let session: (DashboardRow, SessionAgent?) -> Void
    let sessionMark: (DashboardRow) -> PageSessionMark?
    /// Which of the two pull-request sections this is. Both offer the same columns and open on the
    /// same four; the section decides only which saved layout the header menu writes to.
    enum Kind: String { case mine, review }
    let kind: Kind
    @State private var sortOrder = [KeyPathComparator(\DashboardRow.sortDate, order: .reverse)]
    @State private var selection: DashboardRow.ID?
    /// Which columns are shown, in what order, at what width — right-click the header to change it.
    /// The two sections keep separate layouts, so hiding Branch on one leaves the other alone.
    @AppStorage private var columns: TableColumnCustomization<DashboardRow>

    init(rows: [DashboardRow], opening: String?, open: @escaping (DashboardRow) -> Void,
         openTab: @escaping (DashboardRow) -> Void, session: @escaping (DashboardRow, SessionAgent?) -> Void,
         sessionMark: @escaping (DashboardRow) -> PageSessionMark?, kind: Kind) {
        self.rows = rows
        self.opening = opening
        self.open = open
        self.openTab = openTab
        self.session = session
        self.sessionMark = sessionMark
        self.kind = kind
        _columns = AppStorage(wrappedValue: Self.defaultColumns, "dashboard.columns.\(kind.rawValue)")
    }

    /// Both sections open on Pull Request, Session, Repository and Age — what a row is triaged by,
    /// with room left for the title. Tags, Jira, Author and Branch are opt-in through the header's
    /// right-click menu; eight columns at once leave the title nothing to read in.
    private static let defaultColumns: TableColumnCustomization<DashboardRow> = {
        var value = TableColumnCustomization<DashboardRow>()
        for id in ["tags", "jira", "author", "branch"] { value[visibility: id] = .hidden }
        return value
    }()
    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 28

    /// Stamp each row with its session's name so the Session column can sort, then order. Live:
    /// this is recomputed with the body, so starting a session re-sorts with it.
    private var sorted: [DashboardRow] {
        rows.map { row in
            var row = row; row.sessionName = sessionMark(row)?.shortName ?? ""; return row
        }.sorted(using: sortOrder)
    }
    private func row(_ id: DashboardRow.ID?) -> DashboardRow? { rows.first { $0.id == id } }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            titleColumn; sessionColumn; tagsColumn; jiraColumn
            authorColumn; repoColumn; branchColumn; ageColumn
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .scrollDisabled(true)
        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(rows.count))
        .contextMenu(forSelectionType: DashboardRow.ID.self) { ids in
            if let row = row(ids.first) {
                PageRowMenu(hasSession: sessionMark(row) != nil, open: { openTab(row) }, session: { session(row, $0) })
            }
        } primaryAction: { ids in
            if let row = row(ids.first) { open(row) }
        }
    }


    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var titleColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Pull Request", value: \.title) { row in
            HStack(spacing: 8) {
                ChecksIcon(row: row)
                Text(row.number).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Button(action: { open(row) }) {
                    Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain).disabled(opening == row.url.absoluteString)
                    .accessibilityIdentifier("dashboard-pr-\(row.pr.number ?? 0)")
                if let status = row.reviewLabel { OutlinedTag(text: status, tint: Self.reviewTint(status)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .width(min: 200, ideal: 380)
        // Resizable and reorderable, but never hideable: it holds the only link out of the row.
        .disabledCustomizationBehavior(.visibility)
        .customizationID("title")
    }
    /// Which agent is running on the pull request's worktree, or nothing when it has no session.
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var sessionColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Session", value: \.sessionName) { row in SessionCell(mark: sessionMark(row)) }
            .width(min: 72, ideal: 92, max: 180)
            .customizationID("session")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var tagsColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Tags", value: \.sortTags) { row in TagList(tags: row.tags) }
            .width(min: 80, ideal: 150, max: 340)
            .customizationID("tags")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var jiraColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Jira", value: \.sortJira) { row in
            Text((row.pr.jiraKeys ?? []).prefix(2).joined(separator: " "))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
        }.width(min: 72, ideal: 92, max: 200).customizationID("jira")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var authorColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Author", value: \.author) { row in
            Text(row.author).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }.width(min: 72, ideal: 92, max: 200).customizationID("author")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var repoColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Repository", value: \.sortRepo) { row in
            Text(row.sortRepo).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }.width(min: 90, ideal: 118, max: 260).customizationID("repo")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var branchColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Branch", value: \.sortBranch) { row in
            Text(row.sortBranch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
        }.width(min: 100, ideal: 150, max: 340).customizationID("branch")
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var ageColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Age", value: \.sortAge) { row in
            Text(row.ageLabel).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .help(row.dateLabel ?? "")
        }.width(min: 46, ideal: 56, max: 110).customizationID("age")
    }

    static func reviewTint(_ status: String) -> Color {
        switch status {
        case "Approved": return Theme.success
        case "Draft": return Theme.textTertiary
        default: return Theme.warn
        }
    }
}

/// The CI state as a single glyph ahead of the pull request's number. It had a column of its own
/// and did not earn one: the shapes already separate the four states, so the word was repetition
/// across every row. The state stays readable through the tooltip and VoiceOver.
private struct ChecksIcon: View {
    let row: DashboardRow
    var body: some View {
        Image(systemName: row.ciSymbol).font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint).frame(width: 13)
            .help(row.ciLabel).accessibilityLabel(row.ciLabel)
    }
    private var tint: Color {
        switch row.checks {
        case .passing: return Theme.success
        case .failing: return Theme.danger
        case .running: return Theme.warn
        case .unknown: return Theme.textTertiary
        }
    }
}

/// The pull request's labels. GitHub label colours run as pale as #ededed, so the colour is a mark
/// and the name stays in readable text. Past two, the rest go to the tooltip, not the column.
private struct TagList: View {
    let tags: [DashboardPR.Tag]
    var body: some View {
        HStack(spacing: 7) {
            ForEach(tags.prefix(2), id: \.name) { tag in
                HStack(spacing: 4) {
                    Circle().fill(Theme.tagTint(tag.color)).frame(width: 6, height: 6)
                    Text(tag.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            if tags.count > 2 {
                Text("+\(tags.count - 2)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary).fixedSize()
            }
        }.help(tags.map(\.name).joined(separator: ", "))
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

/// A status word in its own colour, outlined rather than filled.
private struct OutlinedTag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: Theme.Size.hairline))
    }
}

/// The Jira section's table: key and summary open the ticket; the row menu offers its session.
struct DashboardTicketTable: View {
    let rows: [DashboardTicketRow]
    let opening: String?
    let open: (DashboardTicketRow) -> Void
    let openTab: (DashboardTicketRow) -> Void
    let session: (DashboardTicketRow, SessionAgent?) -> Void
    let sessionMark: (DashboardTicketRow) -> PageSessionMark?
    /// Each Jira key a pull request on this dashboard references, against that pull request's
    /// number. The PR column reads it, so a ticket already being worked on says where.
    let linkedPRs: [String: String]
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
            row.pullRequest = linkedPRs[row.ticket.key] ?? ""
            return row
        }.sorted(using: sortOrder)
    }
    private func row(_ id: DashboardTicketRow.ID?) -> DashboardTicketRow? { rows.first { $0.id == id } }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Ticket", value: \.title) { row in
                HStack(spacing: 8) {
                    Text(row.ticket.key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accent)
                    Button(action: { open(row) }) {
                        Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    }.buttonStyle(.plain).disabled(opening == row.url.absoluteString)
                        .accessibilityIdentifier("dashboard-ticket-\(row.ticket.key)")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 200, ideal: 420)
            .disabledCustomizationBehavior(.visibility)
            .customizationID("ticket")
            TableColumn("Status", value: \.status) { row in
                if !row.status.isEmpty {
                    Text(row.status).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(row.inProgress ? Theme.accent : Theme.textSecondary).lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 1.5)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder((row.inProgress ? Theme.accent : Theme.border).opacity(row.inProgress ? 0.35 : 1),
                                          lineWidth: Theme.Size.hairline))
                }
            }.width(min: 90, ideal: 118, max: 240).customizationID("status")
            TableColumn("Type", value: \.type) { row in
                Text(row.type).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }.width(min: 56, ideal: 72, max: 150).customizationID("type")
            TableColumn("Priority", value: \.priority) { row in
                Text(row.priority).font(.system(size: 12, weight: row.urgent ? .semibold : .regular))
                    .foregroundStyle(row.urgent ? Theme.danger : Theme.textSecondary).lineLimit(1)
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

struct DashboardCard: View {
    let row: DashboardRow; let opening: Bool; let open: () -> Void; let openTab: () -> Void; let session: (SessionAgent?) -> Void
    var sessionMark: PageSessionMark? = nil
    private var hasSession: Bool { sessionMark != nil }
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(ciColor).frame(width: 9, height: 9).help(row.ciLabel).accessibilityLabel(row.ciLabel)
                Text(row.number).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 38, alignment: .leading)
                Text(row.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let status = row.reviewLabel { reviewState(status) }
                HStack(spacing: 6) {
                    // The PR's own labels are not shown; the session's agent takes their place.
                    if let mark = sessionMark { AgentChip(mark: mark) }
                    ForEach((row.pr.jiraKeys ?? []).prefix(2), id: \.self) { key in
                        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Color.blue.opacity(0.08), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Text((row.pr.repo ?? row.projectName).split(separator: "/").last.map(String.init) ?? row.projectName)
                    if let branch = row.pr.headRefName, !branch.isEmpty { Text("·").foregroundStyle(.quaternary); Text(branch).lineLimit(1).truncationMode(.middle) }
                }.font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).frame(maxWidth: 230, alignment: .trailing)
                if let login = row.pr.author?.login, !login.isEmpty {
                    Text(String(login.prefix(1)).uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).background(.quaternary.opacity(0.65), in: Circle()).help(login)
                }
                if let date = row.dateLabel { Text(date).font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 54, alignment: .trailing) }
            }.padding(.horizontal, 10).frame(minHeight: 44)
                .background(hovering ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(opening).onHover { hovering = $0 }
            .accessibilityIdentifier("dashboard-pr-\(row.pr.number ?? 0)")
            .contextMenu { PageRowMenu(hasSession: hasSession, open: openTab, session: session) }
    }
    @ViewBuilder private func reviewState(_ status: String) -> some View {
        if status == "Draft" {
            Text(status.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.3).foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        } else {
            Label(status, systemImage: status == "Approved" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(status == "Approved" ? .green : .orange).lineLimit(1)
        }
    }
    private var ciColor: Color {
        if row.ciRunning { return .orange }
        switch row.pr.ci?.conclusion { case "success": return .green; case "failure": return .red; default: return .secondary.opacity(0.5) }
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

/// The session's agent as a tag: its colour as the dot, its name as the text.
private struct AgentChip: View {
    let mark: PageSessionMark
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(mark.shortName).lineLimit(1).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
        }
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: Theme.Size.hairline))
        .help(mark.label).accessibilityLabel(mark.label)
    }
    private var tint: Color { mark.cli.isEmpty ? Theme.textSecondary : Theme.agentTint(mark.cli) }
}
