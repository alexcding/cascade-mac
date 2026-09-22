import Foundation
import SwiftUI

/// The Dashboard's home: the day's headline numbers, each agent's quota and spend as the tray draws
/// them, the user's pull requests by age, and a summary of their Jira tickets that leads through to the full list.
struct DashboardView: View {
    @Bindable var model: DashboardViewModel
    let shell: ShellStore
    /// How many tickets the home screen lists before View All takes over.
    static let ticketPreview = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.padding(.top, 12).padding(.bottom, 28)
                if let error = model.error { warning(error, retry: true) }
                if let error = model.navigation.error { warning(error) }
                ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, value in warning(value) }
                if model.updated == nil {
                    Text(model.loading ? "Loading pull requests…" : "Connect to load pull requests.").foregroundStyle(.secondary)
                } else {
                    summary.padding(.bottom, 48)
                    // Each list is filtered and sorted once here and passed down.
                    let mine = model.visibleMine.sorted { $0.sortDate < $1.sortDate }
                    let reviews = model.visibleReviews.sorted { $0.sortDate < $1.sortDate }
                    let tickets = model.visibleTickets
                    if model.filtering && mine.isEmpty && reviews.isEmpty && tickets.isEmpty {
                        noMatches
                    } else {
                        let attention = model.attentionTickets(from: tickets, limit: Self.ticketPreview)
                        VStack(alignment: .leading, spacing: 52) {
                            myPullRequests(mine)
                            if !reviews.isEmpty { reviewRequests(reviews) }
                            ticketSummary(tickets, attention: attention)
                        }
                    }
                }
            }
            .padding(.bottom, 40).padding(.trailing, 16)
        }
        .accessibilityIdentifier("native-dashboard")
        .searchable(text: $model.query, placement: .toolbar,
                    prompt: "Search pull requests and tickets")
        .task { await shell.watchUsage() }
        .onDisappear(perform: model.cancelActions)
    }

    // MARK: Header

    /// The greeting leads, with the date as one quiet line under it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(greeting).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let value = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return NSFullUserName().split(separator: " ").first.map { "\(value), \($0)" } ?? value
    }

    // MARK: Summary

    /// One row of chips: the work counts, then each agent's session. Urgent opens My Tickets on
    /// its tag; an agent chip opens the tray's usage panel. A line of context sits under the row.
    private var summary: some View {
        let mine = model.mine, reviews = model.reviews
        let failing = mine.filter { $0.checks == .failing }.count
        let drafts = mine.filter { $0.pr.isDraft == true }.count
        let approved = mine.filter { $0.pr.reviewDecision == "APPROVED" }.count
        // Counts, like the pull request chips beside them, ignore the search.
        let tickets = model.tickets
        let urgent = tickets.filter(\.urgent).count
        let month = [shell.usage?.claude, shell.usage?.codex].compactMap { $0?.history }.flatMap { $0 }.reduce(0) { $0 + $1.cost }
        var context = ["\(drafts) draft\(drafts == 1 ? "" : "s"), \(approved == 0 ? "none" : "\(approved)") approved"]
        if model.ticketsAvailable && !(model.ticketsLoading && tickets.isEmpty) {
            context.append("\(urgent) urgent of \(tickets.count) tickets")
        }
        if month > 0 { context.append("\(UsageStats.money(month, whole: true)) of AI over 30 days") }
        return VStack(alignment: .leading, spacing: 14) {
            FlowRow(spacing: 10, lineSpacing: 10) {
                countChip(mine.count, "Open", symbol: "arrow.triangle.pull", tint: .secondary, interactive: false)
                countChip(failing, "Failing", symbol: "xmark.circle.fill", tint: Theme.danger, emphasis: failing > 0, interactive: false)
                countChip(reviews.count, "To review", symbol: "eye", tint: .secondary, interactive: false)
                if model.ticketsAvailable {
                    Button { model.showTickets(.urgent) } label: {
                        countChip(urgent, "Urgent", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    .buttonStyle(.plain)
                    .help("Show urgent tickets")
                    .accessibilityIdentifier("dashboard-urgent-tickets")
                }
                if DashboardUsageChips.loading(shell) || !DashboardUsageChips.plans(shell.usage).isEmpty {
                    Rectangle().fill(DashboardPalette.buttonBorder).frame(width: 1, height: 24).padding(.horizontal, 6)
                        .frame(height: 40)
                    DashboardUsageChips(shell: shell)
                }
            }
            Text(context.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                .monospacedDigit().padding(.leading, 4)
        }
    }

    private func countChip(_ value: Int, _ title: String, symbol: String, tint: Color, emphasis: Bool = false,
                           interactive: Bool = true) -> some View {
        DashboardChip(interactive: interactive) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text("\(value)").font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(emphasis ? DashboardPalette.criticalText : Color.primary)
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pull requests

    /// Yours oldest first, each ending in its draft state and age as quiet text. The refresh here
    /// syncs every pull request, review requests included.
    private func myPullRequests(_ rows: [DashboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "My pull requests", detail: "\(rows.count) open",
                                   refresh: { model.syncPRs() }, busy: model.loading || model.syncing, id: "prs")
            if model.projects.isEmpty {
                noProjects
            } else {
                if rows.isEmpty {
                    Text(model.filtering ? "None match the search." : "No open pull requests you authored.")
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3).padding(.vertical, 12)
                }
                prRows(rows)
            }
        }
    }

    /// Other people's pull requests waiting on the user, as their own section; left out when none are.
    private func reviewRequests(_ rows: [DashboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "Review requested", detail: "\(rows.count) waiting on you")
            prRows(rows)
        }
    }

    private func prRows(_ rows: [DashboardRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            prRow(row, first: index == 0)
        }
    }

    private func prRow(_ row: DashboardRow, first: Bool) -> some View {
        let mark = model.sessionMark(row)
        return DashboardPRRow(row: row, mark: mark, opening: model.navigation.opening == row.url.absoluteString,
                              first: first, open: { model.open(row) })
            .contextMenu {
                PageRowMenu(hasSession: mark != nil, open: { model.open(row, inTab: true) },
                            session: { model.openSession(row, agent: $0) })
            }
    }

    private var noProjects: some View {
        VStack(spacing: 5) {
            Image(systemName: "folder").imageScale(.large).foregroundStyle(DashboardPalette.ink2)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
                .padding(.bottom, 9)
                .accessibilityHidden(true)
            Text("No projects yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(DashboardPalette.ink2)
            Text("Add one with New Project in the sidebar to track its pull requests.")
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Tickets

    /// Where the tickets stand as My Tickets' stage bar, then the few that need attention. The full
    /// list lives on My Tickets, one click away.
    @ViewBuilder private func ticketSummary(_ rows: [DashboardTicketRow], attention: [DashboardTicketRow]) -> some View {
        if model.ticketsAvailable {
            VStack(alignment: .leading, spacing: 0) {
                DashboardSectionHeader(title: "Tickets", detail: "\(rows.count) assigned to you",
                                       refresh: { model.refreshTickets() }, busy: model.ticketsLoading, id: "tickets")
                if rows.isEmpty && model.ticketsLoading {
                    Text("Loading tickets…").font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
                } else if rows.isEmpty {
                    Text(model.ticketsError ?? (model.filtering ? "None match the search." : "No tickets assigned to you."))
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
                } else {
                    TicketStageBar(tickets: rows) { model.showTickets(.stage($0)) }
                        .padding(.top, 2)
                    Spacer().frame(height: 24)
                    if attention.isEmpty {
                        Text("Nothing in progress or urgent.").font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.ink3).padding(.leading, 8).padding(.vertical, 8)
                    }
                    ForEach(Array(attention.enumerated()), id: \.element.id) { index, row in
                        ticketRow(row, first: index == 0)
                    }
                    Button { model.showTickets() } label: {
                        Text("View all \(rows.count) tickets").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DashboardPalette.link)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14).padding(.leading, 8)
                    .accessibilityIdentifier("dashboard-view-all-tickets")
                }
            }
        }
    }

    private func ticketRow(_ row: DashboardTicketRow, first: Bool) -> some View {
        Button { model.open(row) } label: {
            HStack(spacing: 10) {
                TicketPriorityMark(level: row.level)
                Text(row.ticket.key).font(.system(size: 13.5)).foregroundStyle(DashboardPalette.link)
                    .frame(width: 104, alignment: .leading)
                Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.status).font(.system(size: 12)).lineLimit(1).fixedSize()
                    .foregroundStyle(row.stage == .blocked ? DashboardPalette.criticalText : DashboardPalette.ink3)
            }
            .modifier(DashboardHoverRow(first: first))
        }
        .buttonStyle(.plain)
        .disabled(model.navigation.opening == row.url.absoluteString)
        .accessibilityIdentifier("dashboard-ticket-\(row.ticket.key)")
        .contextMenu {
            PageRowMenu(hasSession: model.sessionMark(row) != nil, open: { model.open(row, inTab: true) },
                        session: { model.openSession(row, agent: $0) })
        }
    }

    // MARK: States

    private var noMatches: some View {
        VStack(spacing: 5) {
            Text("Nothing matches the search").font(.system(size: 13, weight: .semibold)).foregroundStyle(DashboardPalette.ink2)
            Button("Clear the search", action: model.clearFilter).buttonStyle(.link).font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func warning(_ text: String, retry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill"); Spacer()
            if retry { Button("Retry", action: model.refresh) }
        }.font(.callout).foregroundStyle(.orange).padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}

/// A list row's resting and hover state, as tall as My Tickets' rows: full-width hairlines above
/// a group's first row and under every row, so each group reads as one ruled list; a square wash
/// under the pointer that fills the band between the rules.
private struct DashboardHoverRow: ViewModifier {
    var first = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).frame(height: 44)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .overlay(alignment: .top) { if first { rule } }
            .overlay(alignment: .bottom) { rule }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var rule: some View {
        Rectangle().fill(DashboardPalette.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// One pull request on the home screen: checks, number, title, the agent working on it, then
/// its draft state and age as one quiet line of text.
private struct DashboardPRRow: View {
    let row: DashboardRow
    let mark: PageSessionMark?
    let opening: Bool
    let first: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ChecksIcon(row: row)
                Text(row.number).font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(DashboardPalette.ink3).frame(width: 40, alignment: .leading)
                Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sessionIcon.frame(width: 16)
                Text(row.pr.isDraft == true ? "Draft · \(row.ageLabel)" : row.ageLabel)
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                    .fixedSize().frame(minWidth: 30, alignment: .trailing)
            }
            .modifier(DashboardHoverRow(first: first))
        }
        .buttonStyle(.plain)
        .disabled(opening)
        .accessibilityIdentifier("dashboard-pr-\(row.pr.number ?? 0)")
        .help(row.detail)
    }

    @ViewBuilder private var sessionIcon: some View {
        if let mark, let asset = mark.asset {
            Image(asset).renderingMode(.template).resizable().scaledToFit().frame(width: 13, height: 13)
                .foregroundStyle(Theme.agentTint(mark.cli)).help(mark.label).accessibilityLabel(mark.label)
        } else if let mark {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(DashboardPalette.ink3)
                .help(mark.label).accessibilityLabel(mark.label)
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

/// The session's agent as a tag: its colour as the dot, its name as the text.
struct AgentChip: View {
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
