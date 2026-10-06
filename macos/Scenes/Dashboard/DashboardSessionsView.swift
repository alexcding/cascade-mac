import SwiftUI

/// How Overview lays out the sessions: one list grouped by project, or a board by stage.
enum DashboardSessionLayout: String, CaseIterable, Identifiable {
    case list, board
    var id: String { rawValue }
    var title: String {
        switch self {
        case .list: String(localized: "List")
        case .board: String(localized: "Board")
        }
    }
}

/// Overview under its totals: what waits on the user, in an amber box of its own, then every
/// session, either listed under its project or on the board by what it needs next. Every box is at
/// `SessionCorner.box` and anything inside one at `SessionCorner.card`. Everything shown is what the
/// app already holds (`DashboardSession`); a click on a session shows it.
struct DashboardSessionsSection: View {
    let model: DashboardViewModel
    /// Wide enough for the board's columns in one row; narrower, they pair up.
    let wide: Bool
    @AppStorage("dashboard.sessions.layout") private var layout = DashboardSessionLayout.list

    var body: some View {
        let lanes = model.shownSessionLanes
        let waiting = lanes.flatMap(\.rows).filter { $0.stage == .needsYou }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("Sessions").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 12)
                // The tabs' own chips, so the choice reads as one of the page's controls.
                HStack(spacing: 2) {
                    ForEach(DashboardSessionLayout.allCases) { choice in
                        DashboardChip(title: choice.title, count: nil, active: layout == choice,
                                      id: "dashboard-sessions-layout-\(choice.id)") { layout = choice }
                    }
                }
            }
            if !waiting.isEmpty {
                DashboardNeedsYouBox(rows: waiting, lanes: lanes) { model.openSession($0) }
            }
            switch layout {
            case .list: DashboardSessionList(lanes: lanes, model: model)
            // An empty board is four empty columns: one line says it instead.
            case .board where lanes.contains { !$0.rows.isEmpty }: board(lanes)
            case .board:
                Text("No sessions yet").font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    /// Every stage, a column each sharing the page's width; one with no session says so.
    private func board(_ lanes: [DashboardSessionLane]) -> some View {
        let shown = model.sessionColumns(lanes)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: wide ? shown.count : 2)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(shown, id: \.stage) { column in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        DashboardStageChip(stage: column.stage)
                        Spacer(minLength: 4)
                        Text(column.rows.count, format: .number).font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                    }
                    .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 4)
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
                .padding(10)
                // A grey well, so the white cards stand off it.
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dashboard-stage-\(column.stage.id)")
            }
        }
    }
}

/// The list's columns: fixed widths for the short ones, the session and what it is doing sharing
/// the rest.
private enum SessionColumn {
    /// Wide enough for the longest stage tag, so every tag starts and the session after it lines up.
    static let status: CGFloat = 84
    static let pullRequest: CGFloat = 150
    static let agent: CGFloat = 92
    static let spacing: CGFloat = 14
    /// A box's inner edge, for its headers and rows alike.
    static let inset: CGFloat = 16
}

/// The section's corners: a box's, as Automation's table and the totals strip have, and anything
/// nested in one.
private enum SessionCorner {
    static let box: CGFloat = 10
    static let card: CGFloat = 8
}

/// The sessions waiting on an answer, across every shown project, ahead of the rest.
private struct DashboardNeedsYouBox: View {
    let rows: [DashboardSessionRow]
    let lanes: [DashboardSessionLane]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .medium))
                Text("Needs you")
                Text(rows.count, format: .number).monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DashboardPalette.attentionText)
            .padding(.horizontal, 6).frame(height: 26)
            ForEach(rows) { row in
                DashboardNeedsYouRow(row: row, project: lanes.first { $0.id == row.session.projectID }?.summary.name) {
                    open(row.id)
                }
            }
        }
        .padding(8)
        .background(DashboardPalette.attention, in: RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous).strokeBorder(DashboardPalette.attentionRule))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-needs-you")
    }
}

/// One session waiting on the user: its name, its project and branch, and how long it has waited.
private struct DashboardNeedsYouRow: View {
    let row: DashboardSessionRow
    let project: String?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.session.title).font(.system(size: 13, weight: .medium))
                    Text([project ?? "", row.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                DashboardSessionTiming(row: row).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DashboardPalette.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hovering ? Theme.surfaceHover : Theme.paneBackground,
                        in: RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous).strokeBorder(DashboardPalette.attentionRule))
            .contentShape(RoundedRectangle(cornerRadius: SessionCorner.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Show \(row.session.title)"))
        .accessibilityIdentifier("dashboard-needs-you-\(row.id)")
    }
}

/// Every shown project, a table each in Automation's look: its name above, then quiet column
/// titles on the tinted strip and its sessions as ruled rows, in a lightly filled box.
private struct DashboardSessionList: View {
    let lanes: [DashboardSessionLane]
    let model: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(lanes) { lane in
                VStack(alignment: .leading, spacing: 8) {
                    title(lane)
                    table(lane)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("dashboard-lane-\(lane.id)")
            }
        }
    }

    /// The project's folder and name, which open it, and how many of its sessions are under way. A
    /// sync that failed says so, with the reason on hover; one that worked says nothing.
    private func title(_ lane: DashboardSessionLane) -> some View {
        let summary = lane.summary
        let active = lane.rows.filter { $0.stage == .needsYou || $0.stage == .working }.count
        return HStack(alignment: .center, spacing: 10) {
            Button { model.openProject(summary.id) } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(nsImage: SidebarIcons.mark("folderClosed", size: 14) ?? NSImage())
                        .renderingMode(.template).foregroundStyle(DashboardPalette.ink3).accessibilityHidden(true)
                    Text(summary.name).font(.system(size: 14, weight: .medium))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open \(summary.name)"))
            .accessibilityIdentifier("dashboard-project-\(summary.id)")
            if !lane.rows.isEmpty {
                Group {
                    if active > 0 {
                        Text("\(active) active · ^[\(lane.rows.count) session](inflect: true)")
                    } else {
                        Text("^[\(lane.rows.count) session](inflect: true)")
                    }
                }
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
            }
            Spacer(minLength: 12)
            if let error = summary.syncError {
                Text("Sync failed").font(.system(size: 12)).foregroundStyle(DashboardPalette.criticalText).help(error)
            }
        }
        .padding(.horizontal, 2)
    }

    private func table(_ lane: DashboardSessionLane) -> some View {
        VStack(spacing: 0) {
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
            if !lane.chats.isEmpty {
                Divider().overlay(DashboardPalette.hairline)
                Text("Chats").textCase(.uppercase)
                    .font(.system(size: 10.5, weight: .medium)).tracking(0.5).foregroundStyle(DashboardPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SessionColumn.inset).frame(height: 36)
                    .background(Color.primary.opacity(0.025))
                    .accessibilityHidden(true)
                ForEach(lane.chats) { chat in
                    Divider().overlay(DashboardPalette.hairline)
                    DashboardChatRowView(chat: chat) { model.openChat(chat.id) }
                }
            }
        }
        .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SessionCorner.box, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
    }

    /// The column titles, as Automation's table sets them, laid out as the rows are.
    private var headings: some View {
        HStack(spacing: SessionColumn.spacing) {
            heading("Status").frame(width: SessionColumn.status, alignment: .leading)
            heading("Session").frame(maxWidth: .infinity, alignment: .leading)
            heading("Doing now").frame(maxWidth: .infinity, alignment: .leading)
            heading("Pull request").frame(width: SessionColumn.pullRequest, alignment: .leading)
            heading("Agent").frame(width: SessionColumn.agent, alignment: .leading)
        }
        .padding(.horizontal, SessionColumn.inset).frame(height: 36)
        .background(Color.primary.opacity(0.025))
        .accessibilityHidden(true)
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).textCase(.uppercase)
            .font(.system(size: 10.5, weight: .medium)).tracking(0.5)
            .foregroundStyle(DashboardPalette.ink3).lineLimit(1)
    }
}

/// A stage's tag: its name, or a row's own state word, on a soft fill of the stage's colour. It
/// heads a column on the board and leads each row of a project's table.
private struct DashboardStageChip: View {
    let stage: DashboardSessionStage
    var title: String?
    var body: some View {
        DashboardTag(text: title ?? stage.title, tint: DashboardPalette.stageChip(stage))
    }
}

/// A session's row: its stage's tag, name over branch and ticket, what it is doing over how long,
/// its pull request and its agent. The whole row shows the session.
private struct DashboardSessionRowView: View {
    let row: DashboardSessionRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: SessionColumn.spacing) {
                DashboardStageChip(stage: row.stage, title: row.stateLabel)
                    .frame(width: SessionColumn.status, alignment: .leading)
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
                DashboardSessionAgent(cli: row.session.cli).frame(width: SessionColumn.agent, alignment: .leading)
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

/// A chat session's row in its project's lane, in the session rows' columns: its state, its title,
/// its agent. The whole row opens the chat.
private struct DashboardChatRowView: View {
    let chat: DashboardChat
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: SessionColumn.spacing) {
                DashboardStageChip(stage: chat.stage, title: chat.stateLabel)
                    .frame(width: SessionColumn.status, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left").font(.system(size: 11)).foregroundStyle(DashboardPalette.ink3)
                    Text(chat.title).font(.system(size: 13, weight: .medium))
                }
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                DashboardSessionAgent(cli: chat.cli).frame(width: SessionColumn.agent, alignment: .leading)
            }
            .padding(.horizontal, SessionColumn.inset).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(String(localized: "Show \(chat.title)"))
        .accessibilityIdentifier("dashboard-chat-\(chat.id)")
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
        let waiting = row.stage == .needsYou
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let lane { Text(lane.summary.name) }
                    if let ticket = row.session.ticket, !ticket.isEmpty { Text("· \(ticket)") }
                }
                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
                Text(row.session.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if waiting {
                    Text("Waiting for your answer").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardPalette.attentionText)
                } else {
                    let parts = row.activityParts
                    Text("\(parts.lead) \(parts.rest)").font(.system(size: 12))
                        .foregroundStyle(DashboardPalette.ink2).lineLimit(1).truncationMode(.middle)
                }
                // Wraps rather than cuts off: a narrow card puts the run time on a line of its own.
                FlowRow(spacing: 12, lineSpacing: 4) {
                    DashboardSessionAgent(cli: row.session.cli)
                    if let pr = row.pr {
                        HStack(spacing: 4) {
                            DashboardChecksIcon(checks: pr.checks)
                            Text(pr.number).monospacedDigit()
                        }
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.ink3).fixedSize()
                    }
                    DashboardSessionTiming(row: row).fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(12)
            .background(hovering ? Theme.surfaceHover : Theme.paneBackground,
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

/// The agent's mark, in the page's grey rather than its own colour, and its short name.
private struct DashboardSessionAgent: View {
    let cli: String?
    var body: some View {
        HStack(spacing: 5) {
            if let cli { AgentMark(key: cli, size: 12, tint: DashboardPalette.ink3) }
            Text(cli.flatMap { AgentDrivers.of($0)?.shortName } ?? String(localized: "Agent"))
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink2).lineLimit(1)
        }
    }
}

/// A pull request's checks as a circled mark: grey while they pass or run, red when one fails.
private struct DashboardChecksIcon: View {
    let checks: DashboardRow.Checks
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(checks == .failing ? DashboardPalette.criticalText : DashboardPalette.ink3)
            .help(checks.sessionLabel)
            .accessibilityLabel(checks.sessionLabel)
    }

    private var symbol: String {
        switch checks {
        case .passing: "checkmark.circle"
        case .running: "circle.dotted"
        case .failing: "xmark.circle"
        case .unknown: "circle"
        }
    }
}

/// The open pull request on the session's branch: its checks, its number and its review state.
private struct DashboardSessionPR: View {
    let pr: DashboardRow?
    var body: some View {
        if let pr {
            HStack(spacing: 6) {
                DashboardChecksIcon(checks: pr.checks)
                Text(pr.number).font(.system(size: 12.5)).monospacedDigit()
                Text(pr.reviewLabel ?? String(localized: "Open")).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
            }
            .lineLimit(1)
        } else {
            Text("No pull request").font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3.opacity(0.75))
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
