import Foundation
import SwiftUI

/// Projects' home. An underline tab bar at the top of the page picks what the page lists: Overview,
/// the totals across every project and a table with one row per project, whose name opens that
/// project's page; Pull Requests, every pull request a section per project; Tickets, every ticket;
/// Board, the picked project's Jira sprint board.
struct DashboardView: View {
    @Bindable var model: DashboardViewModel
    let shell: ShellStore
    /// Below this width the totals pair up.
    private static let splitWidth: CGFloat = 900
    @State private var width: CGFloat = 1200

    var body: some View {
        Group {
            if model.tab == .board {
                // The board fills the page rather than scrolling with it: each column scrolls on its own.
                VStack(alignment: .leading, spacing: 0) {
                    tabBar
                    boardPage
                }
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tabBar
                        if let error = model.navigation.error { warning(error) }
                        if model.tab == .tickets {
                            DashboardTicketsPage(model: model)
                        } else {
                            if model.tab == .pullRequests { header.padding(.bottom, 24) }
                            if let error = model.prs.error { warning(error, retry: true) }
                            if model.prs.unreachable { warning(String(localized: "GitHub is not answering. Showing saved pull requests.")) }
                            ForEach(Array(model.prs.warnings.enumerated()), id: \.offset) { _, value in warning(value) }
                            if model.prs.updated == nil {
                                Text(model.prs.loading ? String(localized: "Loading pull requests…") : String(localized: "Connect to load pull requests.")).foregroundStyle(.secondary)
                            } else if model.tab == .pullRequests {
                                pullRequestsPage
                            } else {
                                overview
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    // The page inset lives inside the scroll view, so its scroller runs down the window's edge.
                    .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 40)
                }
            }
        }
        .accessibilityIdentifier("native-dashboard")
        .onDisappear(perform: model.cancelActions)
    }

    /// The tabs, and at their end the project every tab narrows to.
    private var tabBar: some View {
        DashboardUnderlineTabs(values: model.tabs, selection: model.tab,
                               title: \.title, id: "dashboard-tabs") { model.selectTab($0) } trailing: {
            DashboardProjectTag(projects: model.prs.projects, selection: model.project,
                                id: "dashboard-project") { model.selectProject($0) }
                .disabled(model.prs.projects.isEmpty)
        }
        .padding(.bottom, 20)
    }

    // MARK: Board

    /// The picked project's sprint board, the whole team's, to move and assign; with no project
    /// picked, or one without a board, the projects that have one.
    @ViewBuilder private var boardPage: some View {
        if let board = model.board {
            HStack(alignment: .center, spacing: 12) {
                BoardFilters(board: board)
                Spacer(minLength: 12)
                if let sprint = board.sprintTitle {
                    Text(sprint).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
                }
                DashboardRefreshButton(name: String(localized: "Sprint board"), id: "board", busy: board.loading, action: board.reload)
            }
            .padding(.bottom, 20)
            WebBoardView(model: board).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("dashboard-board")
                .onDisappear(perform: board.cancelActions)
        } else {
            let projects = model.prs.projects.filter { model.boardProjectIDs.contains($0.id) }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.projectShowsBoard ? String(localized: "Connect to load the board.")
                     : model.project != nil ? String(localized: "This project has no sprint board. Turn on Show board in its Settings.")
                     : String(localized: "Pick a project to see its sprint board."))
                    .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
                if !model.projectShowsBoard {
                    FlowRow(spacing: 4, lineSpacing: 6) {
                        ForEach(projects) { project in
                            DashboardChip(title: project.name, count: nil, active: false,
                                          id: "dashboard-board-project-\(project.id)") { model.selectProject(project.id) }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Header

    /// The Pull Requests tab's one row of controls: whose, then the filters that matter, then how
    /// old the list is and Refresh. The age is drawn again each minute: nothing else redraws it
    /// while nobody is looking, and what it says grows older all the same.
    private var header: some View {
        let prs = model.prs
        return HStack(alignment: .top, spacing: 12) {
            FlowRow(spacing: 4, lineSpacing: 6) {
                ForEach(DashboardPullRequestsModel.Author.allCases) { author in
                    DashboardChip(title: author.title, count: prs.count(author), active: prs.author == author,
                                  id: "dashboard-pr-author-\(author.id)") { prs.author = author }
                }
                DashboardChipDivider()
                ForEach(DashboardPullRequestsModel.Filter.shown(with: prs.filter)) { filter in
                    DashboardChip(title: filter.title, count: prs.counts[filter] ?? 0, active: prs.filter == filter,
                                  id: "dashboard-pr-filter-\(filter.id)") { prs.filter = filter }
                }
            }
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(updatedLabel).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                }
                DashboardRefreshButton(name: String(localized: "Pull requests"), id: "prs",
                                       busy: prs.loading || prs.syncing, action: { prs.sync() })
            }
            .fixedSize()
        }
    }

    /// How old the pull requests shown are, read again whenever the model reads: the page
    /// refreshes behind a look, so what it shows says how long ago that was.
    private var updatedLabel: String {
        guard let synced = model.prs.synced else { return "" }
        let now = Date()
        guard now.timeIntervalSince(synced) >= 60 else { return String(localized: "Updated just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return String(localized: "Updated \(formatter.localizedString(for: synced, relativeTo: now))")
    }

    // MARK: Overview

    /// Every project at a glance: the totals across them, then one row each.
    @ViewBuilder private var overview: some View {
        let all = model.projectSummaries
        let projects = model.project.map { id in all.filter { $0.id == id } } ?? all
        if all.isEmpty {
            noProjects
        } else {
            VStack(alignment: .leading, spacing: 24) {
                totals(projects)
                projectTable(projects)
            }
        }
    }

    /// The headline numbers, each the size of the list it opens: the user's own pull requests, the
    /// ones waiting on them, their own failing, and their tickets once a tracker answers.
    private func totals(_ projects: [DashboardProjectSummary]) -> some View {
        let tickets = model.tickets.available
        let mine = model.prs.mine.filter { model.project == nil || $0.projectID == model.project }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                            count: width >= Self.splitWidth ? (tickets ? 4 : 3) : 2)
        return LazyVGrid(columns: columns, spacing: 12) {
            total(String(localized: "Your open pull requests"), mine.count, id: "open") {
                model.showPullRequests(.mine)
            }
            total(String(localized: "Waiting on you"), model.prs.count(.review), id: "waiting") {
                model.showPullRequests(.review)
            }
            total(String(localized: "Your failing checks"), mine.filter { $0.checks == .failing }.count, critical: true, id: "failing") {
                model.showPullRequests(.mine, filter: .failing)
            }
            if tickets {
                total(String(localized: "Tickets assigned"),
                      model.project == nil ? model.tickets.rows.count : projects.reduce(0) { $0 + $1.tickets }, id: "tickets") {
                    model.showTickets()
                }
            }
        }
    }

    /// One headline number, a button to the list it counts.
    private func total(_ title: String, _ value: Int, critical: Bool = false, id: String, open: @escaping () -> Void) -> some View {
        DashboardTotal(title: title, value: value, critical: critical, id: "dashboard-total-\(id)", open: open)
    }

    /// One row per project, its name a button to the project's page. Ages are drawn again each
    /// minute, as nothing else redraws them while nobody is looking.
    private func projectTable(_ projects: [DashboardProjectSummary]) -> some View {
        let tickets = model.tickets.available
        return TimelineView(.periodic(from: .now, by: 60)) { _ in
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    Text("Project")
                    Text("Open PRs")
                    Text("Waiting on you")
                    Text("Checks")
                    if tickets { Text("Tickets") }
                    Text("Sessions")
                    // The last column takes the rest of the width, so the grid and its dividers fill the card.
                    Text("Updated").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DashboardPalette.ink3)
                .padding(.vertical, 10)
                ForEach(projects) { project in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Button { model.openProject(project.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.system(size: 13, weight: .semibold))
                                Text(project.tracker).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open \(project.name)"))
                        .accessibilityIdentifier("dashboard-project-\(project.id)")
                        Text(project.open, format: .number)
                        Text(project.waiting, format: .number)
                        HStack(spacing: 6) {
                            Circle().fill(checksColor(project)).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(project.checks)
                        }
                        if tickets { Text(project.tickets, format: .number) }
                        Text(project.sessions, format: .number)
                        updated(project).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 13)).monospacedDigit()
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DashboardPalette.hairline))
        }
    }

    private func checksColor(_ project: DashboardProjectSummary) -> Color {
        if project.failing > 0 { return DashboardPalette.critical }
        if project.running > 0 { return Theme.warn }
        return project.passing > 0 ? Theme.success : DashboardPalette.hairline
    }

    /// How long ago the project synced, or that its sync failed, with the reason on hover.
    @ViewBuilder private func updated(_ project: DashboardProjectSummary) -> some View {
        if let error = project.syncError {
            Text("Sync failed").foregroundStyle(DashboardPalette.criticalText).help(error)
        } else if let synced = project.synced {
            Text(synced.timeIntervalSinceNow > -60 ? String(localized: "Just now")
                 : synced.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .foregroundStyle(DashboardPalette.ink3)
        } else {
            Text("Waiting for first sync").foregroundStyle(DashboardPalette.ink3)
        }
    }

    // MARK: Pull requests

    private func prRows(_ rows: [DashboardRow], author: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            prRow(row, first: index == 0, author: author)
        }
    }

    private func prRow(_ row: DashboardRow, first: Bool, author: Bool) -> some View {
        let mark = model.sessionMark(row)
        return DashboardPRRow(row: row, mark: mark, opening: model.navigation.opening == row.url.absoluteString,
                              first: first, showsAuthor: author, open: { model.open(row) })
            .contextMenu {
                PageRowMenu(hasSession: mark != nil, url: row.url, open: { model.open(row) })
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
            Text("Add one with New Project to track its pull requests and tickets.")
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Pull Requests tab

    /// The user's own, their review queue's, or everyone else's open pull requests, one ruled
    /// section per project, narrowed by a tag and optionally to one project.
    private var pullRequestsPage: some View {
        let groups = model.prs.groups
        return VStack(alignment: .leading, spacing: 0) {
            if model.prs.projects.isEmpty {
                noProjects
            } else if groups.isEmpty {
                placeholder(String(localized: "No pull requests here."))
            } else {
                VStack(alignment: .leading, spacing: 44) {
                    ForEach(groups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            DashboardSectionHeader(title: group.project.name, detail: group.project.repo,
                                                   busy: model.prs.loading || model.prs.syncing, id: "prs")
                            prRows(group.rows, author: model.prs.author != .mine)
                        }
                    }
                }
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
            if retry { Button("Retry") { model.prs.refresh(look: true) } }
        }.font(.callout).foregroundStyle(.orange).padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}

/// One choice in a tab's row of controls: its name and how many it leaves, a soft grey fill and
/// full ink when chosen, quiet grey otherwise.
/// Whose and which filter share this one face, so the row reads as one set of controls.
struct DashboardChip: View {
    let title: String
    let count: Int?
    let active: Bool
    let id: String
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(active ? Color.primary : DashboardPalette.ink3)
                if let count { Text(count, format: .number).monospacedDigit().foregroundStyle(DashboardPalette.ink3) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 28)
            .background(active ? Theme.surfaceHover : hovering ? Theme.surfaceHover.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The gap between a row's whose and its filters.
struct DashboardChipDivider: View {
    var body: some View {
        Color.clear.frame(width: 12, height: 28).accessibilityHidden(true)
    }
}

/// An Overview total: what it counts and how many, in a ruled box that opens that list, washed
/// under the pointer.
struct DashboardTotal: View {
    let title: String
    let value: Int
    let critical: Bool
    let id: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                Text(value, format: .number).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(critical && value > 0 ? DashboardPalette.criticalText : Color.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(hovering ? Theme.surfaceHover.opacity(0.6) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DashboardPalette.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}

/// The page's tabs as a row of titles over a hairline, the chosen one in full ink with a bar under
/// it that slides to the next choice, and `trailing` at the far end. `id` prefixes each tab's
/// accessibility id.
struct DashboardUnderlineTabs<Value: Hashable & Identifiable, Trailing: View>: View {
    let values: [Value]
    let selection: Value
    let title: (Value) -> String
    let id: String
    let select: (Value) -> Void
    /// What sits at the bar's far end, over the hairline: controls that apply to every tab.
    @ViewBuilder var trailing: Trailing
    @Namespace private var slide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 22) {
            ForEach(values) { value in
                let active = value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { select(value) }
                } label: {
                    Text(title(value))
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.primary : DashboardPalette.ink3)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if active {
                                Rectangle().fill(Color.primary).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: slide)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id)-\(value.id)")
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 12)
            trailing
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DashboardPalette.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Building blocks

/// The project a page narrows to, as an outlined tag that opens a menu, All Projects first.
struct DashboardProjectTag: View {
    let projects: [DashboardProject]
    let selection: String?
    let id: String
    let select: (String?) -> Void

    var body: some View {
        let selected = projects.first { $0.id == selection }
        Menu {
            Picker("Project", selection: Binding(get: { selection }, set: select)) {
                Text("All Projects").tag(String?.none)
                Divider()
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            // Drawn as the tab bar's titles are, in plain text, rather than as an outlined tag.
            HStack(spacing: 4) {
                Text(selected?.name ?? String(localized: "All Projects"))
                    .font(.system(size: 13, weight: selected != nil ? .semibold : .regular))
                    .foregroundStyle(selected != nil ? Color.primary : DashboardPalette.ink2)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DashboardPalette.ink3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier(id)
    }
}

/// A row of tags that narrow a list, each with its count; the selected one filled.
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
                    DashboardTagLabel(title: title(value), count: count(value), active: active)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id(value))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

/// One tag's face: its name, then a count or a symbol; filled when selected.
/// A tag's words in the tag face: its title, then its count and symbol, light on a filled tag.
struct DashboardTagText: View {
    let title: String
    var count: Int?
    var symbol: String?
    let filled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title).fontWeight(.semibold)
            if let count { Text("\(count)").monospacedDigit().opacity(0.7) }
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).opacity(0.7) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(filled ? Color(nsColor: .windowBackgroundColor) : Color.primary)
    }
}

struct DashboardTagLabel: View {
    let title: String
    var count: Int?
    var symbol: String?
    let active: Bool
    /// The page header's scope tags (whose, which project): selected is a heavier ring, never a
    /// fill, so they read apart from the filled filter tags below them.
    var outlined = false

    var body: some View {
        let filled = active && !outlined
        DashboardTagText(title: title, count: count, symbol: symbol, filled: filled)
            .padding(.horizontal, 12).frame(height: 30)
        .background(filled ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(active ? Color.primary : DashboardPalette.buttonBorder, lineWidth: active && outlined ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

/// A list row's resting and hover state, as tall as the Tickets tab's rows: full-width hairlines above
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
/// working on it and its age.
struct DashboardPRRow: View {
    let row: DashboardRow
    let mark: PageSessionMark?
    let opening: Bool
    let first: Bool
    /// Others' and review requests name who opened them.
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
                if let key = row.pr.ticketLabels.first {
                    Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(DashboardPalette.link)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.accentBackground, in: Capsule())
                }
                reviewState
                if let mark { AgentChip(mark: mark) }
                if showsAuthor, !row.author.isEmpty {
                    Text(row.author).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
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
            if row.pr.isDraft == true {
                Text(status.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(DashboardPalette.ink3)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
            } else {
                let approved = row.pr.reviewDecision == "APPROVED"
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
    private var tint: Color { mark.cli.isEmpty ? Theme.textSecondary : AgentDrivers.driver(for: mark.cli).tint }
}
