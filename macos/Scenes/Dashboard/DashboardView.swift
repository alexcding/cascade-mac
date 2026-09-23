import Foundation
import SwiftUI

/// The Dashboard's home: the day's headline numbers as four tiles, then ruled lists: the user's
/// pull requests and a summary of their Jira tickets, with review requests and each agent's quota
/// beside them. Tabs swap the body for every pull request or every review request; Tickets opens
/// My Tickets.
struct DashboardView: View {
    @Bindable var model: DashboardViewModel
    let shell: ShellStore
    /// Below this width the side column drops under the main one and the tiles pair up.
    private static let splitWidth: CGFloat = 900
    /// The side column's width, unless the tile above it is wider.
    private static let sideWidth: CGFloat = 340
    @State private var width: CGFloat = 1200
    /// The tiles share their row equally; the side column lines up with them once they outgrow it.
    @State private var tileWidth: CGFloat = 0
    /// What each tile last showed lives on the model, not in this view: My Tickets replaces this
    /// view while it is pushed, and view state would come back at zero and roll up again.
    private func shown(_ key: String) -> Binding<Double> {
        Binding { model.tileValues[key, default: 0] } set: { model.tileValues[key] = $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.top, 12).padding(.bottom, 24)
                if let error = model.prs.error { warning(error, retry: true) }
                if let error = model.navigation.error { warning(error) }
                ForEach(Array(model.prs.warnings.enumerated()), id: \.offset) { _, value in warning(value) }
                if model.prs.updated == nil {
                    Text(model.prs.loading ? "Loading pull requests…" : "Connect to load pull requests.").foregroundStyle(.secondary)
                } else {
                    switch model.tab {
                    case .pullRequests: pullRequestsPage
                    case .reviews: reviewsPage
                    case .overview, .tickets: overview
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // The page inset lives inside the scroll view, so its scroller runs down the window's edge.
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
        }
        .accessibilityIdentifier("native-dashboard")
        .task { await shell.watchUsage() }
        .onChange(of: shell.usage, initial: true) { _, usage in model.usage.update(usage) }
        .onDisappear(perform: model.cancelActions)
    }

    // MARK: Header

    /// Each tab's title in the one page-header style; the tabs themselves live in the toolbar.
    private var header: some View {
        switch model.tab {
        case .pullRequests: DashboardPageHeader(caption: "Yours, newest first", title: "Pull requests")
        case .reviews: DashboardPageHeader(caption: "Waiting on you, newest first", title: "Review requested")
        case .overview, .tickets:
            DashboardPageHeader(caption: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)), title: greeting)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let value = hour < 5 ? "Up late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return NSFullUserName().split(separator: " ").first.map { "\(value), \($0)" } ?? value
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary.padding(.bottom, 44)
            let mine = model.prs.mine
            let reviews = model.prs.reviews
            let tickets = model.tickets.rows
            let attention = model.tickets.attention
            // The side column only when it has something in it; otherwise the lists take the width.
            if width >= Self.splitWidth && (!reviews.isEmpty || showsUsage) {
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 52) {
                        myPullRequests(mine)
                        ticketSummary(tickets, attention: attention)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 52) {
                        if !reviews.isEmpty { reviewRequests(reviews) }
                        usage
                    }
                    .frame(width: max(Self.sideWidth, tileWidth))
                }
            } else {
                VStack(alignment: .leading, spacing: 52) {
                    myPullRequests(mine)
                    if !reviews.isEmpty { reviewRequests(reviews) }
                    ticketSummary(tickets, attention: attention)
                    usage
                }
            }
        }
    }

    // MARK: Summary

    /// The headline tiles: the user's pull requests by check state, the reviews waiting on them,
    /// their tickets by stage once Jira is connected, and the month's agent spend. Counts ignore the
    /// search; the sections under them leave their counts to these tiles. One row when wide, sized
    /// to the tiles shown so none leaves an empty slot; pairs when narrow.
    private var summary: some View {
        let tiles = model.tickets.available ? 4 : 3
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                            count: width >= Self.splitWidth ? tiles : 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            pullRequestTile
            reviewTile
            if model.tickets.available { ticketTile }
            spendTile
        }
    }

    private var pullRequestTile: some View {
        let tile = model.prs.tile
        return DashboardStatTile(title: "Open pull requests", value: Double(tile.count), shown: shown("prs"),
                                 footnote: tile.footnote,
                                 open: { model.selectTab(.pullRequests) }) {
            if tile.failing > 0 { DashboardBadge("\(tile.failing) failing", tone: .danger) }
        } visual: {
            DashboardChecksMatrix(rows: tile.dots)
        }
        .accessibilityIdentifier("dashboard-tile-prs")
    }

    private var reviewTile: some View {
        let tile = model.prs.reviewTile
        return DashboardStatTile(title: "Waiting on you", value: Double(tile.count), shown: shown("reviews"),
                                 footnote: tile.footnote,
                                 open: { model.selectTab(.reviews) }) {
            if let age = tile.oldestAge { DashboardBadge("oldest \(age)", tone: .warn) }
        } visual: {
            DashboardAvatarStack(logins: tile.authors, avatars: model.prs.avatars)
        }
        .accessibilityIdentifier("dashboard-tile-reviews")
    }

    /// Urgent opens My Tickets on its tag; a segment of the strip opens it on that stage.
    private var ticketTile: some View {
        let tile = model.tickets.tile
        let loading = model.tickets.loading && tile.count == 0
        return DashboardStatTile(title: "Tickets assigned", value: loading ? 0 : Double(tile.count), shown: shown("tickets"),
                                 footnote: tile.footnote,
                                 open: { model.showTickets() }) {
            if tile.urgent > 0 {
                Button { model.showTickets(.urgent) } label: { DashboardBadge("\(tile.urgent) urgent", tone: .danger) }
                    .buttonStyle(.plain)
                    .help("Show urgent tickets")
                    .accessibilityIdentifier("dashboard-urgent-tickets")
            }
        } visual: {
            DashboardStageStrip(stages: model.tickets.stages) { model.showTickets(.stage($0)) }
                .frame(minWidth: 40, maxWidth: 110)
        }
        .accessibilityIdentifier("dashboard-tile-tickets")
    }

    private var spendTile: some View {
        let tile = model.usage.tile
        return DashboardStatTile(title: "AI spend · 30 days", value: tile.month, shown: shown("spend"), format: { UsageStats.money($0, whole: true) },
                                 footnote: tile.footnote) {
            if let label = tile.tokensLabel { DashboardBadge(label, tone: .outline) }
        } visual: {
            DashboardSpendLines(lines: tile.lines, peak: tile.peak)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tileWidth = $0 }
        .accessibilityIdentifier("dashboard-tile-spend")
    }

    // MARK: Pull requests

    /// Yours newest first. The refresh here syncs every pull request, review requests included.
    private func myPullRequests(_ rows: [DashboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "My pull requests", detail: "",
                                   refresh: { model.prs.sync() }, busy: model.prs.loading || model.prs.syncing, id: "prs")
            if model.prs.projects.isEmpty {
                noProjects
            } else {
                if rows.isEmpty { placeholder("No open pull requests you authored.") }
                prRows(rows)
            }
        }
    }

    /// Other people's pull requests waiting on the user, as their own section; left out when none are.
    private func reviewRequests(_ rows: [DashboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "Review requested", detail: "")
            // Compact only in the side column; full width has room for the agent and Draft state.
            prRows(rows, compact: width >= Self.splitWidth)
        }
    }

    private func prRows(_ rows: [DashboardRow], compact: Bool = false, author: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            prRow(row, first: index == 0, compact: compact, author: author)
        }
    }

    private func prRow(_ row: DashboardRow, first: Bool, compact: Bool, author: Bool) -> some View {
        let mark = model.sessionMark(row)
        return DashboardPRRow(row: row, mark: mark, opening: model.navigation.opening == row.url.absoluteString,
                              first: first, compact: compact, showsAuthor: author, open: { model.open(row) })
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

    // MARK: Pull Requests tab

    /// Every pull request of the user's, one ruled section per project, narrowed by a tag.
    private var pullRequestsPage: some View {
        let groups = model.prs.groups
        return VStack(alignment: .leading, spacing: 0) {
            DashboardFilterTags(values: DashboardPullRequestsModel.Filter.allCases, selection: model.prs.filter,
                                title: \.title, count: { model.prs.counts[$0] ?? 0 },
                                id: { "dashboard-pr-filter-\($0.id)" }) { model.prs.filter = $0 }
                .padding(.bottom, 24)
            if model.prs.projects.isEmpty {
                noProjects
            } else if groups.isEmpty {
                placeholder("No pull requests here.")
            } else {
                VStack(alignment: .leading, spacing: 44) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        VStack(alignment: .leading, spacing: 0) {
                            DashboardSectionHeader(title: group.project.name, detail: group.project.repo,
                                                   refresh: index == 0 ? { model.prs.sync() } : nil,
                                                   busy: model.prs.loading || model.prs.syncing, id: "prs")
                            prRows(group.rows)
                        }
                    }
                }
            }
        }
    }

    // MARK: Reviews tab

    /// Every review request, longest waiting first, with who asked.
    private var reviewsPage: some View {
        let reviews = model.prs.reviews
        return VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "Waiting on you", detail: "",
                                   refresh: { model.prs.sync() }, busy: model.prs.loading || model.prs.syncing, id: "reviews")
            if reviews.isEmpty {
                placeholder("No review requests.")
            }
            prRows(reviews, author: true)
        }
    }

    // MARK: Tickets

    /// The few tickets that need attention; the tile above already splits them by stage, and the
    /// full list lives on My Tickets, one click away.
    @ViewBuilder private func ticketSummary(_ rows: [DashboardTicketRow], attention: [DashboardTicketRow]) -> some View {
        if model.tickets.available {
            VStack(alignment: .leading, spacing: 0) {
                DashboardSectionHeader(title: "Tickets", detail: "",
                                       refresh: { model.tickets.refresh() }, busy: model.tickets.loading, id: "tickets")
                if rows.isEmpty && model.tickets.loading {
                    placeholder("Loading tickets…")
                } else if rows.isEmpty {
                    placeholder(model.tickets.error ?? "No tickets assigned to you.")
                } else {
                    if attention.isEmpty { placeholder("Nothing in progress or urgent.") }
                    ForEach(Array(attention.enumerated()), id: \.element.id) { index, row in
                        ticketRow(row, first: index == 0)
                    }
                    Button { model.showTickets() } label: {
                        Text("View all tickets").font(.system(size: 13, weight: .semibold))
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
                TicketStatusPill(row: row)
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

    // MARK: Usage

    /// Each agent's quota as a ruled row with a ring; a row opens the tray's usage panel.
    private var showsUsage: Bool { DashboardUsage.loading(shell) || !DashboardUsage.plans(shell.usage).isEmpty }

    @ViewBuilder private var usage: some View {
        if showsUsage {
            VStack(alignment: .leading, spacing: 0) {
                DashboardSectionHeader(title: "Agent usage", detail: "")
                DashboardUsageRows(shell: shell)
            }
        }
    }

    // MARK: States

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3).padding(.vertical, 12)
    }

    private func warning(_ text: String, retry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill"); Spacer()
            if retry { Button("Retry", action: model.prs.refresh) }
        }.font(.callout).foregroundStyle(.orange).padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}

// MARK: - Building blocks

/// Every Dashboard tab's title: one quiet caption over the page's name, and any trailing control
/// level with the name. Overview, Pull Requests, Reviews and My Tickets all open with it.
struct DashboardPageHeader<Trailing: View>: View {
    let caption: String
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(.system(size: 13, weight: .medium)).foregroundStyle(DashboardPalette.ink3)
                    .monospacedDigit()
                Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.6)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DashboardPageHeader where Trailing == EmptyView {
    init(caption: String, title: String) { self.init(caption: caption, title: title) { EmptyView() } }
}

/// The Dashboard's tabs as the system's segmented picker, so it takes Liquid Glass on macOS 26
/// like the toolbar around it. Tickets joins once a Jira-capable service connects.
struct DashboardTabBar: View {
    let selection: DashboardViewModel.Tab
    var tickets = true
    let select: @MainActor @Sendable (DashboardViewModel.Tab) -> Void

    var body: some View {
        Picker("Dashboard section", selection: Binding(get: { selection }, set: select)) {
            ForEach(DashboardViewModel.Tab.allCases.filter { tickets || $0 != .tickets }) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize()
        .accessibilityIdentifier("dashboard-tabs")
    }
}

/// A row of tags that narrow a list, each with its count; the selected one filled, as on My Tickets.
struct DashboardFilterTags<Value: Hashable>: View {
    let values: [Value]
    let selection: Value
    let title: (Value) -> String
    let count: (Value) -> Int
    let id: (Value) -> String
    let select: (Value) -> Void

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(values, id: \.self) { value in
                let active = value == selection
                Button { select(value) } label: {
                    HStack(spacing: 7) {
                        Text(title(value)).fontWeight(.semibold)
                        Text("\(count(value))").monospacedDigit().opacity(0.7)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(active ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(active ? Color.primary : DashboardPalette.buttonBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id(value))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

/// One headline number in an outlined tile: its name and badge on top, the figure in the rounded
/// face with a small visual beside it, then one quiet line.
private struct DashboardStatTile<Badge: View, Visual: View>: View {
    let title: String
    /// The count or amount; the tile starts at zero and rolls up to it once the data is in.
    let value: Double
    /// The number on screen, which follows `value` with a roll.
    @Binding var shown: Double
    var format: (Double) -> String = { "\(Int($0))" }
    let footnote: String
    /// Where a click on the tile goes: the tab that lists what it counts. Controls inside the tile,
    /// such as the urgent badge, keep their own clicks.
    var open: (() -> Void)? = nil
    @ViewBuilder let badge: Badge
    @ViewBuilder let visual: Visual

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Baseline-aligned, so the title and the badge's text sit on one line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DashboardPalette.ink2).lineLimit(1)
                Spacer(minLength: 0)
                badge
            }
            .frame(minHeight: 22)
            HStack(alignment: .center, spacing: 8) {
                Text(format(shown)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                    // No scaling, so every tile's number is the same size; the visual gives way instead.
                    .tracking(-0.6).lineLimit(1).fixedSize().layoutPriority(1)
                    .contentTransition(.numericText(value: shown))
                    .onChange(of: value, initial: true) {
                        guard shown != value else { return }
                        withAnimation(reduceMotion ? nil : .snappy) { shown = value }
                    }
                Spacer(minLength: 0)
                visual
            }
            // A fixed row height keeps every tile the same height whatever its visual.
            .frame(height: 42)
            Text(footnote).font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // A visual drawn wider than the room a narrow tile leaves it stops at the card's edge.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // A tap rather than a Button, so the tile's own buttons stay separate controls.
        .onTapGesture { open?() }
        .accessibilityElement(children: .contain)
        .modifier(DashboardTileAction(open: open))
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// Makes a tile a VoiceOver button only when it has somewhere to go, so the spend tile offers no
/// action that does nothing.
private struct DashboardTileAction: ViewModifier {
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content.accessibilityAddTraits(.isButton).accessibilityAction { open() }
        } else {
            content
        }
    }
}

/// An outlined capsule label; only its text is tinted by what it says, so every tile's badge
/// shares one quiet style.
private struct DashboardBadge: View {
    enum Tone { case danger, warn, outline }
    let text: String
    let tone: Tone
    init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }

    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).frame(height: 22)
            .overlay(Capsule().strokeBorder(DashboardPalette.hairline, lineWidth: 1))
    }
    private var foreground: Color {
        switch tone {
        case .danger: DashboardPalette.criticalText
        case .warn: DashboardPalette.pill(.inProgress).text
        case .outline: DashboardPalette.ink2
        }
    }
}

/// One rounded square per open pull request, coloured by its check state, in a GitHub-style
/// matrix two high that fills column by column. In a narrow tile it drops whole columns from the
/// end rather than push past the tile's edge; failing ones come first, so they are never dropped.
private struct DashboardChecksMatrix: View {
    let rows: [DashboardRow]
    private static let cell: CGFloat = 8
    private static let gap: CGFloat = 3
    private static let columns = [10, 8, 6, 4, 2]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.columns, id: \.self) { count in grid(Array(rows.prefix(count * 2))) }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }
    private func grid(_ rows: [DashboardRow]) -> some View {
        LazyHGrid(rows: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.gap), count: 2), spacing: Self.gap) {
            ForEach(rows) { row in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint(row.checks))
                    .frame(width: Self.cell, height: Self.cell)
            }
        }
        .fixedSize()
    }
    private func tint(_ checks: DashboardRow.Checks) -> Color {
        switch checks {
        case .passing: Theme.success
        case .failing: Theme.danger
        case .running: Theme.warn
        case .unknown: DashboardPalette.buttonBorder
        }
    }
}

/// Up to three authors as overlapping initials.
private struct DashboardAvatarStack: View {
    let logins: [String]
    /// GitHub faces by login; a login missing here shows its initials.
    var avatars: [String: NSImage] = [:]
    private static let tints: [ThemeTone] = [.accent, .merged, .success]
    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(logins.enumerated()), id: \.offset) { index, login in
                let tone = Self.tints[index % Self.tints.count]
                Group {
                    if let avatar = avatars[login] {
                        Image(nsImage: avatar).resizable().scaledToFill()
                    } else {
                        Text(String(login.prefix(2)).uppercased()).font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(tone.foreground)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(tone.background)
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .help(login)
            }
        }
        .accessibilityLabel(logins.joined(separator: ", "))
    }
}

/// The month's daily cost as one line per agent, each in its colour, on a shared scale.
private struct DashboardSpendLines: View {
    let lines: [DashboardUsageModel.Line]
    let peak: Double
    var body: some View {
        ZStack {
            ForEach(lines) { line in
                Path { path in
                    let points = line.costs
                    guard points.count > 1 else { return }
                    for (index, cost) in points.enumerated() {
                        let point = CGPoint(x: 100 * CGFloat(index) / CGFloat(points.count - 1), y: 32 - 30 * CGFloat(cost / peak))
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }
                .stroke(Theme.agentTint(line.key), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(minWidth: 40, maxWidth: 100, minHeight: 34, maxHeight: 34)
        .accessibilityHidden(true)
    }
}

/// The tickets by stage as one short strip.
private struct DashboardStageStrip: View {
    let stages: DashboardTicketsModel.StageSummary
    let select: (TicketStage) -> Void
    var body: some View {
        let total = CGFloat(max(1, stages.total))
        GeometryReader { geometry in
            let gaps = CGFloat(max(0, stages.live.count - 1)) * 3
            HStack(spacing: 3) {
                ForEach(stages.live) { entry in
                    Button { select(entry.stage) } label: {
                        Capsule().fill(DashboardPalette.stage(entry.stage))
                            .frame(width: max(6, (geometry.size.width - gaps) * CGFloat(entry.count) / total), height: 8)
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.stage.title): \(entry.count)")
                    .accessibilityLabel("\(entry.stage.title): \(entry.count)")
                }
            }
        }
        .frame(height: 8)
    }
}

/// A list row's resting and hover state, as tall as My Tickets' rows: full-width hairlines above
/// a group's first row and under every row, so each group reads as one ruled list; a square wash
/// under the pointer that fills the band between the rules.
struct DashboardHoverRow: ViewModifier {
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

/// One pull request: checks, number, title, then the ticket it names, its review state, the agent
/// working on it and its age. The side column's compact form keeps checks, number, title and age.
struct DashboardPRRow: View {
    let row: DashboardRow
    let mark: PageSessionMark?
    let opening: Bool
    let first: Bool
    var compact = false
    /// The Reviews tab names who asked.
    var showsAuthor = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ChecksIcon(row: row)
                Text(row.number).font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(DashboardPalette.ink3).frame(width: 40, alignment: .leading)
                Text(row.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    if let key = row.pr.jiraKeys?.first {
                        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(DashboardPalette.link)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.accentBackground, in: Capsule())
                    }
                    reviewState
                    if let mark { AgentChip(mark: mark) }
                    if showsAuthor, !row.author.isEmpty {
                        Text(row.author).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
                    }
                }
                Text(row.ageLabel)
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

    @ViewBuilder private var reviewState: some View {
        if let status = row.reviewLabel {
            if status == "Draft" {
                Text(status.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(DashboardPalette.ink3)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
            } else {
                let approved = status == "Approved"
                Label(status, systemImage: approved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    .foregroundStyle(approved ? DashboardPalette.pill(.pendingRelease).text : DashboardPalette.pill(.inProgress).text)
            }
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
