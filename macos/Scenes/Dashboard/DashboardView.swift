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
                    section("GitHub · My Pull Requests", rows: model.mine, empty: "No open PRs you authored.", showsBranch: false)
                    section("Review Requested", rows: model.reviews, empty: "Nothing awaiting your review.")
                    if model.ticketsAvailable { ticketSection }
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

    private func section(_ title: String, rows: [DashboardRow], empty: String, showsBranch: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(title).font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                Text("\(rows.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary.opacity(0.55), in: Capsule())
            }.padding(.bottom, 10)
            Divider().padding(.bottom, rows.isEmpty ? 14 : 0)
            if rows.isEmpty { Text(empty).font(.system(size: 13)).foregroundStyle(.tertiary) }
            else {
                DashboardTable(rows: rows, opening: model.navigation.opening,
                    open: { model.open($0) }, session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark,
                    showsBranch: showsBranch)
            }
        }.padding(.bottom, 36)
    }

    private var ticketSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("Jira · My Tickets").font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                Text("\(model.tickets.count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary.opacity(0.55), in: Capsule())
            }.padding(.bottom, 10)
            Divider().padding(.bottom, model.tickets.isEmpty ? 14 : 0)
            if let error = model.ticketsError, model.tickets.isEmpty {
                Text(error).font(.system(size: 13)).foregroundStyle(.tertiary)
            } else if model.tickets.isEmpty {
                Text(model.ticketsLoaded ? "No open tickets assigned to you." : "Loading tickets…").font(.system(size: 13)).foregroundStyle(.tertiary)
            } else {
                DashboardTicketTable(rows: model.tickets, opening: model.navigation.opening,
                    open: { model.open($0) }, session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark,
                    linkedKeys: Set(model.visibleRows.flatMap { $0.pr.jiraKeys ?? [] }))
            }
        }.padding(.bottom, 36)
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
    let session: (DashboardRow, SessionAgent?) -> Void
    let sessionMark: (DashboardRow) -> PageSessionMark?
    /// Off for the user's own pull requests, where the branch is theirs and rarely worth a column.
    var showsBranch = true
    @State private var sortOrder = [KeyPathComparator(\DashboardRow.sortDate, order: .reverse)]
    @State private var selection: DashboardRow.ID?
    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 28

    private var sorted: [DashboardRow] { rows.sorted(using: sortOrder) }
    private func row(_ id: DashboardRow.ID?) -> DashboardRow? { rows.first { $0.id == id } }

    var body: some View {
        Group {
            if showsBranch {
                Table(sorted, selection: $selection, sortOrder: $sortOrder) { leading; branchColumn; trailing }
            } else {
                Table(sorted, selection: $selection, sortOrder: $sortOrder) { leading; trailing }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .scrollDisabled(true)
        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(rows.count))
        .contextMenu(forSelectionType: DashboardRow.ID.self) { ids in
            if let row = row(ids.first) {
                PageRowMenu(hasSession: sessionMark(row) != nil, open: { open(row) }, session: { session(row, $0) })
            }
        } primaryAction: { ids in
            if let row = row(ids.first) { open(row) }
        }
    }


    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var leading: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Pull Request", value: \.title) { row in
            HStack(spacing: 8) {
                Circle().fill(ciColor(row)).frame(width: 7, height: 7).help(row.ciLabel).accessibilityLabel(row.ciLabel)
                Text(row.number).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary)
                Button(action: { open(row) }) {
                    Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain).disabled(opening == row.url.absoluteString)
                    .accessibilityIdentifier("dashboard-pr-\(row.pr.number ?? 0)")
                if let status = row.reviewLabel { reviewState(status) }
                if let mark = sessionMark(row) { AgentChip(mark: mark) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.width(min: 260)
        TableColumn("Jira", value: \.sortJira) { row in
            HStack(spacing: 4) {
                ForEach((row.pr.jiraKeys ?? []).prefix(2), id: \.self) { key in
                    Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Color.blue.opacity(0.08), in: Capsule())
                }
            }
        }.width(110)
        TableColumn("Repository", value: \.sortRepo) { row in
            Text(row.sortRepo).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }.width(140)
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var branchColumn: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Branch", value: \.sortBranch) { row in
            Text(row.sortBranch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }.width(180)
    }
    @TableColumnBuilder<DashboardRow, KeyPathComparator<DashboardRow>> private var trailing: some TableColumnContent<DashboardRow, KeyPathComparator<DashboardRow>> {
        TableColumn("Created", value: \.sortDate) { row in
            Text(row.dateLabel ?? "").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
        }.width(96)
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
    private func ciColor(_ row: DashboardRow) -> Color {
        if row.ciRunning { return .orange }
        switch row.pr.ci?.conclusion { case "success": return .green; case "failure": return .red; default: return .secondary.opacity(0.5) }
    }
}

/// The Jira section's table: key and summary open the ticket; the row menu offers its session.
struct DashboardTicketTable: View {
    let rows: [DashboardTicketRow]
    let opening: String?
    let open: (DashboardTicketRow) -> Void
    let session: (DashboardTicketRow, SessionAgent?) -> Void
    let sessionMark: (DashboardTicketRow) -> PageSessionMark?
    /// Jira keys a PR row on the dashboard already carries; their sessions are shown on the PR.
    let linkedKeys: Set<String>
    @State private var sortOrder: [KeyPathComparator<DashboardTicketRow>] = []
    @State private var selection: DashboardTicketRow.ID?
    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 28

    private var sorted: [DashboardTicketRow] { rows.sorted(using: sortOrder) }
    private func row(_ id: DashboardTicketRow.ID?) -> DashboardTicketRow? { rows.first { $0.id == id } }

    var body: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Ticket", value: \.title) { row in
                HStack(spacing: 8) {
                    Text(row.ticket.key).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.tertiary)
                    Button(action: { open(row) }) {
                        Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    }.buttonStyle(.plain).disabled(opening == row.url.absoluteString)
                        .accessibilityIdentifier("dashboard-ticket-\(row.ticket.key)")
                    // A ticket with a PR on the dashboard shows its session there, not twice.
                    if !linkedKeys.contains(row.ticket.key), let mark = sessionMark(row) { AgentChip(mark: mark) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.width(min: 260)
            TableColumn("Status", value: \.status) { row in
                Text(row.status).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary.opacity(0.45), in: Capsule())
            }.width(120)
            TableColumn("Type", value: \.type) { row in
                Text(row.type).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }.width(64)
            TableColumn("Priority", value: \.priority) { row in
                Text(row.priority).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }.width(64)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .scrollDisabled(true)
        .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(rows.count))
        .contextMenu(forSelectionType: DashboardTicketRow.ID.self) { ids in
            if let row = row(ids.first) {
                PageRowMenu(hasSession: sessionMark(row) != nil, open: { open(row) }, session: { session(row, $0) })
            }
        } primaryAction: { ids in
            if let row = row(ids.first) { open(row) }
        }
    }
}

struct DashboardCard: View {
    let row: DashboardRow; let opening: Bool; let open: () -> Void; let session: (SessionAgent?) -> Void
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
            .contextMenu { PageRowMenu(hasSession: hasSession, open: open, session: session) }
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

/// The session's agent as a tag: its colour as the dot, its name as the text.
private struct AgentChip: View {
    let mark: PageSessionMark
    var body: some View {
        Text(mark.shortName).lineLimit(1)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(mark.cli.isEmpty ? Color.secondary : Theme.agentTint(mark.cli), in: Capsule())
            .help(mark.label).accessibilityLabel(mark.label)
    }
}
