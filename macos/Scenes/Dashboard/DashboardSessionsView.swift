import SwiftUI

/// Overview under its totals: each project in a table of its sessions, two side by side across the
/// page's width, in the Automation table's look, then the session board, the same sessions by what
/// they need next. The board's columns are at the top cards' `SessionCorner.box`, everything inside
/// one at `SessionCorner.card`. Everything shown is what the app already holds (`DashboardSession`); a
/// click on a session shows it.
struct DashboardSessionsSection: View {
    let model: DashboardViewModel
    /// Wide enough for the board's columns in one row; narrower, they pair up.
    let wide: Bool

    var body: some View {
        let lanes = model.shownSessionLanes
        VStack(alignment: .leading, spacing: 16) {
            // Two to a row while the page is wide, one under another when it is not.
            let pair = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: wide ? 2 : 1)
            LazyVGrid(columns: pair, alignment: .leading, spacing: 16) {
                ForEach(lanes) { lane in
                    DashboardSessionLaneView(lane: lane, model: model)
                }
            }
            if lanes.contains(where: { !$0.rows.isEmpty }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Session board").font(.system(size: 14, weight: .medium)).padding(.top, 16).padding(.bottom, 12)
                    board(lanes)
                }
            }
        }
    }

    /// Every stage, a column each sharing the page's width; one with no session says so.
    private func board(_ lanes: [DashboardSessionLane]) -> some View {
        let shown = model.sessionColumns(lanes)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: wide ? shown.count : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(shown, id: \.stage) { column in
                let tint = DashboardPalette.sessionStage(column.stage)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(tint.dot).frame(width: 7, height: 7)
                        Text(column.stage.title).font(.system(size: 13, weight: .medium))
                        Text(column.rows.count, format: .number).font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                    }
                    .padding(.horizontal, 2)
                    if column.rows.isEmpty {
                        Text("No sessions").font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .overlay(RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous)
                                .strokeBorder(DashboardPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    ForEach(column.rows) { row in
                        DashboardSessionCard(row: row, lane: lanes.first { $0.id == row.session.projectID }) {
                            model.openSession(row.id)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous).strokeBorder(DashboardPalette.hairline))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dashboard-stage-\(column.stage.id)")
            }
        }
    }
}

/// The lane rows' columns: fixed widths for the short ones, the session and what it is doing
/// sharing the rest. The headings and every row are laid out by the same numbers, so they line up.
private enum SessionColumn {
    static let state: CGFloat = 96
    static let pullRequest: CGFloat = 150
    static let spacing: CGFloat = 16
    /// A box's inner edge, for its header, headings and rows alike.
    static let inset: CGFloat = 16
}

/// The section's corners: a board column's, as the top cards have, that of a card inside one, and a
/// project's table, as Automation's has.
private enum SessionCorner {
    static let box: CGFloat = 20
    static let card: CGFloat = 12
    static let table: CGFloat = 10
}

/// One project's table, drawn as Automation's: its name in the tinted header row, then quiet column
/// headings and its sessions as ruled rows, in a lightly filled box.
private struct DashboardSessionLaneView: View {
    let lane: DashboardSessionLane
    let model: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DashboardPalette.hairline)
            if lane.rows.isEmpty {
                Text("No sessions yet").font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                headings
                ForEach(lane.rows) { row in
                    Divider().overlay(DashboardPalette.hairline)
                    DashboardSessionRowView(row: row) { model.openSession(row.id) }
                }
            }
        }
        .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: SessionCorner.table, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: SessionCorner.table, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SessionCorner.table, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-lane-\(lane.id)")
    }

    private var summary: DashboardProjectSummary { lane.summary }

    /// The project's badge and name in the rows' own size. A sync that failed says so at the end,
    /// with the reason on hover; one that worked says nothing.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.openProject(summary.id) } label: {
                HStack(alignment: .center, spacing: 10) {
                    DashboardProjectBadge()
                    Text(summary.name).font(.system(size: 14, weight: .medium))
                    Text([lane.repo, summary.tracker].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open \(summary.name)"))
            .accessibilityIdentifier("dashboard-project-\(summary.id)")
            Spacer(minLength: 12)
            if let error = summary.syncError {
                Text("Sync failed").font(.system(size: 12)).foregroundStyle(DashboardPalette.criticalText).help(error)
            }
        }
        .padding(.horizontal, SessionColumn.inset).frame(height: 44)
        .background(Color.primary.opacity(0.025))
    }

    /// The column headings, laid out as the rows are, quiet under the tinted name.
    private var headings: some View {
        HStack(spacing: SessionColumn.spacing) {
            Text("State").frame(width: SessionColumn.state, alignment: .leading)
            Text("Session").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text("Doing now").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text("Pull request").frame(width: SessionColumn.pullRequest, alignment: .leading)
        }
        .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
        .padding(.horizontal, SessionColumn.inset).frame(height: 32)
        .accessibilityHidden(true)
    }
}

/// The project's folder, the sidebar's closed one, on a pale square.
private struct DashboardProjectBadge: View {
    var body: some View {
        Image(nsImage: SidebarIcons.mark("folderClosed", size: 13) ?? NSImage())
            .renderingMode(.template)
            .foregroundStyle(DashboardPalette.ink2)
            .frame(width: 22, height: 22)
            .background(DashboardPalette.ink3.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A session's row, in the Pull Requests list's type and rules: its state, name over branch and
/// ticket, what it is doing over how long, and its pull request. The whole row shows the session.
private struct DashboardSessionRowView: View {
    let row: DashboardSessionRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let tint = DashboardPalette.sessionStage(row.stage)
        Button(action: open) {
            HStack(spacing: SessionColumn.spacing) {
                HStack(spacing: 7) {
                    Circle().fill(tint.dot).frame(width: 7, height: 7)
                    Text(row.stateLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(tint.text)
                }
                .frame(width: SessionColumn.state, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.session.title).font(.system(size: 13, weight: .medium))
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    }
                }
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    activity.font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    DashboardSessionTiming(row: row)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                DashboardSessionPR(pr: row.pr).frame(width: SessionColumn.pullRequest, alignment: .leading)
            }
            .padding(.horizontal, SessionColumn.inset).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Show \(row.session.title)"))
        .accessibilityIdentifier("dashboard-session-\(row.id)")
    }

    /// The tool, a little heavier, then what it acted on.
    private var activity: Text {
        let parts = row.activityParts
        return parts.rest.isEmpty ? Text(parts.lead).fontWeight(.medium)
            : Text("\(Text(parts.lead).fontWeight(.medium)) \(parts.rest)")
    }
}

/// A session on the board: its project and ticket, its name, what it waits on or does, then its
/// agent, its pull request and how long it has run.
private struct DashboardSessionCard: View {
    let row: DashboardSessionRow
    let lane: DashboardSessionLane?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let lane { Text(lane.summary.name) }
                    if let ticket = row.session.ticket, !ticket.isEmpty { Text("· \(ticket)") }
                }
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
                Text(row.session.title).font(.system(size: 13.5)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.stage == .needsYou {
                    Text("Waiting for your answer").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardPalette.sessionStage(.needsYou).text)
                } else {
                    let parts = row.activityParts
                    Text("\(Text(parts.lead).fontWeight(.medium)) \(parts.rest)").font(.system(size: 12))
                        .foregroundStyle(DashboardPalette.ink2).lineLimit(1).truncationMode(.middle)
                }
                // Wraps rather than cuts off: a narrow card puts the run time on a line of its own.
                FlowRow(spacing: 10, lineSpacing: 4) {
                    DashboardSessionAgent(cli: row.session.cli)
                    if let pr = row.pr {
                        let checks = DashboardPalette.checks(pr.checks)
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(checks.dot).frame(width: 7, height: 7)
                            Text(pr.number).monospacedDigit()
                        }
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).fixedSize()
                    }
                    DashboardSessionTiming(row: row).fixedSize()
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(hovering ? Color.primary.opacity(0.04) : Color.clear,
                        in: RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous).strokeBorder(DashboardPalette.hairline))
            .contentShape(RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("dashboard-session-card-\(row.id)")
    }
}

/// How long the session's call and agent have run: the one part of a row that changes with time.
/// Drawn again every few seconds while a call is under way, every minute otherwise.
private struct DashboardSessionTiming: View {
    let row: DashboardSessionRow
    var body: some View {
        TimelineView(.periodic(from: .now, by: row.ticksBySecond ? 5 : 60)) { context in
            let text = row.timing(now: context.date)
            if !text.isEmpty {
                Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
            }
        }
    }
}

/// The agent's mark and its short name.
private struct DashboardSessionAgent: View {
    let cli: String?
    var body: some View {
        HStack(spacing: 6) {
            if let cli { AgentMark(key: cli, size: 14) }
            Text(cli.flatMap { AgentDrivers.of($0)?.shortName } ?? String(localized: "Agent")).font(.system(size: 12.5)).lineLimit(1)
        }
    }
}

/// The open pull request on the session's branch: its number and review state over its checks.
private struct DashboardSessionPR: View {
    let pr: DashboardRow?
    var body: some View {
        if let pr {
            let checks = DashboardPalette.checks(pr.checks)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(pr.number) · \(pr.reviewLabel ?? String(localized: "Open"))").font(.system(size: 12.5)).monospacedDigit().lineLimit(1)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(checks.dot).frame(width: 7, height: 7)
                    Text(pr.checks.sessionLabel).font(.system(size: 12)).foregroundStyle(checks.text).lineLimit(1)
                }
            }
        } else {
            Text("No pull request").font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
        }
    }
}

private extension DashboardRow.Checks {
    /// The checks in the lanes' words.
    var sessionLabel: String {
        switch self {
        case .passing: String(localized: "Checks passing")
        case .running: String(localized: "Checks running")
        case .failing: String(localized: "Checks failing")
        case .unknown: String(localized: "No checks")
        }
    }
}
