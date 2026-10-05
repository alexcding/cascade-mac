import SwiftUI

/// Automation: every pipeline as a row of a table across the page, or the open one as a page of
/// its own. The toolbar (`Destination.windowToolbar`) carries the page's name, the way back from
/// a pipeline, the search over the table and New. Webhook forwarding is under Settings → Integrations.
struct AutomationView: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        Group {
            if model.draft?.kind == .schedule {
                AutomationScheduleEditorView(model: model)
            } else if model.draft != nil {
                AutomationEditorView(model: model)
            } else if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.automations.isEmpty && model.newKeys.isEmpty {
                AutomationEmptyState(model: model)
            } else {
                AutomationTablePage(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneSurface()
        .accessibilityIdentifier("automation-screen")
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }
}

/// Back to the table from an open pipeline, its unsaved work kept.
struct AutomationBackButton: View {
    let model: AutomationViewModel
    var body: some View {
        Button { model.close() } label: {
            Label("Automations", systemImage: "chevron.left")
        }
        .help(String(localized: "Back to all automations"))
        .accessibilityIdentifier("automation-back")
    }
}

/// New at the toolbar's trailing edge: a scheduled agent run or an event pipeline, blank or from
/// one of the catalogue's templates.
struct AutomationNewMenu: View {
    let model: AutomationViewModel
    var body: some View {
        let templates = model.catalog?.templates ?? []
        Menu {
            Button("Scheduled Automation", systemImage: "clock") { model.create(.schedule) }
            Button("Event Automation", systemImage: "bolt") { model.create(.event) }
            ForEach([Automation.Kind.schedule, .event], id: \.self) { kind in
                let matching = templates.filter { $0.automation.kind == kind }
                if !matching.isEmpty {
                    Divider()
                    Section(kind == .schedule ? String(localized: "Scheduled Templates") : String(localized: "Event Templates")) {
                        ForEach(matching) { template in
                            Button(template.localizedName) { model.create(from: template) }
                        }
                    }
                }
            }
        } label: {
            Label("New Automation", systemImage: "plus").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "New automation"))
        .accessibilityIdentifier("automation-new")
    }
}

/// The table's kind filter beside its search, in the Pull Requests tab's chips: every
/// automation, the scheduled ones, or the event ones, each with its count.
private struct AutomationKindFilter: View {
    let model: AutomationViewModel

    private enum Choice: String, CaseIterable, Hashable {
        case all, scheduled, events
        var kind: Automation.Kind? {
            switch self {
            case .all: nil
            case .scheduled: .schedule
            case .events: .event
            }
        }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .scheduled: String(localized: "Scheduled")
            case .events: String(localized: "Events")
            }
        }
    }

    var body: some View {
        let selection = Choice.allCases.first { $0.kind == model.kindFilter } ?? .all
        HStack(spacing: 4) {
            ForEach(Choice.allCases, id: \.self) { choice in
                DashboardChip(title: choice.title,
                              count: model.automations.filter { choice.kind == nil || $0.kind == choice.kind }.count,
                              active: choice == selection, id: "automation-kind-\(choice.rawValue)") { model.kindFilter = choice.kind }
            }
        }
        .fixedSize()
    }
}

/// Every pipeline as a row: what it is called, what sets it off, where, how it last ran and
/// whether it is on. A row opens the pipeline; its menu switches it or deletes it.
private struct AutomationTablePage: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AutomationSearchField(text: Bindable(model).query)
                    AutomationKindFilter(model: model)
                }
                if model.settings?.paused == true { AutomationPausedNotice(model: model) }
                if let error = model.error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled)
                }
                VStack(spacing: 0) {
                    AutomationTableHeader()
                    ForEach(model.shownAutomations) { automation in
                        Divider().overlay(DashboardPalette.hairline)
                        AutomationTableRow(model: model, automation: automation)
                            .accessibilityIdentifier("automation-row-\(automation.id)")
                    }
                    // Last, where they land once saved: a new pipeline takes the next position.
                    ForEach(model.newDrafts, id: \.key) { item in
                        Divider().overlay(DashboardPalette.hairline)
                        AutomationTableRow(model: model, automation: item.draft, newKey: item.key)
                            .accessibilityIdentifier("automation-row-\(item.key)")
                    }
                    if !model.automations.isEmpty && model.shownAutomations.isEmpty && model.newKeys.isEmpty {
                        Divider().overlay(DashboardPalette.hairline)
                        Text(model.query.isEmpty ? String(localized: "No automations of this kind.") : String(localized: "No automations match “\(model.query)”."))
                            .font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }
                .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
                .accessibilityIdentifier("automation-list")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 40)
        }
    }
}

/// The search over the table, under the toolbar at the page's leading edge.
private struct AutomationSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
            TextField("Search automations", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                .accessibilityIdentifier("automation-search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DashboardPalette.ink3)
                }
                .buttonStyle(.plain).help(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 10).frame(width: 320, height: 30)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : DashboardPalette.hairline, lineWidth: 1))
        .onExitCommand { text = "" }
    }
}

/// The table's columns, shared by its header and every row so they line up.
private enum AutomationColumn {
    static let projects: CGFloat = 130
    static let nextRun: CGFloat = 140
    static let lastRun: CGFloat = 150
    static let status: CGFloat = 90
    static let menu: CGFloat = 28
    static let spacing: CGFloat = 16
}

private struct AutomationTableHeader: View {
    var body: some View {
        HStack(spacing: AutomationColumn.spacing) {
            title("Name").frame(maxWidth: .infinity, alignment: .leading)
            title("Runs").frame(maxWidth: .infinity, alignment: .leading)
            title("Project").frame(width: AutomationColumn.projects, alignment: .leading)
            title("Next Run").frame(width: AutomationColumn.nextRun, alignment: .leading)
            title("Last Run").frame(width: AutomationColumn.lastRun, alignment: .leading)
            title("Status").frame(width: AutomationColumn.status, alignment: .leading)
            Color.clear.frame(width: AutomationColumn.menu, height: 1)
        }
        .padding(.horizontal, 16).frame(height: 36)
        .background(Color.primary.opacity(0.025))
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text).textCase(.uppercase)
            .font(.system(size: 10.5, weight: .medium)).tracking(0.5)
            .foregroundStyle(DashboardPalette.ink3).lineLimit(1)
    }
}

private struct AutomationTableRow: View {
    let model: AutomationViewModel
    let automation: Automation
    /// Set for a new pipeline not saved yet: its row key in place of an id.
    var newKey: String?
    @State private var hovering = false
    @State private var confirmDelete = false

    private var key: String { newKey ?? automation.id }

    var body: some View {
        HStack(spacing: AutomationColumn.spacing) {
            HStack(spacing: 8) {
                Image(systemName: automation.kind == .schedule ? "clock" : "bolt")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(DashboardPalette.ink3).frame(width: 14)
                    .help(automation.kind == .schedule ? String(localized: "Scheduled") : String(localized: "Runs on an event"))
                Text(automation.name.isEmpty ? String(localized: "Untitled automation") : automation.name)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if newKey == nil && model.hasUnsavedEdits(automation.id) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .help("Edited, not saved").accessibilityLabel("Edited, not saved")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(automation.kind == .schedule ? automation.schedule.summary : automation.triggerSummary(model.catalog))
                .frame(maxWidth: .infinity, alignment: .leading)
            cell(projects).frame(width: AutomationColumn.projects, alignment: .leading)
            cell(nextRun).frame(width: AutomationColumn.nextRun, alignment: .leading)
            lastRun.frame(width: AutomationColumn.lastRun, alignment: .leading)
            status.frame(width: AutomationColumn.status, alignment: .leading)
            menu.frame(width: AutomationColumn.menu)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(key) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .confirmationDialog("Delete this automation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(id: automation.id) } }
        } message: {
            Text("Existing Activity entries are kept.")
        }
    }

    private func cell(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink2)
            .lineLimit(1).truncationMode(.tail)
    }

    /// When a scheduled one that is on runs next; an event one has no next run.
    private var nextRun: String {
        guard automation.kind == .schedule else { return "—" }
        guard let next = automation.nextRun else { return automation.mode == .live ? "—" : String(localized: "Off") }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: next) else { return next }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var projects: String {
        if automation.kind == .schedule {
            return model.projects.first { $0.id == automation.schedule.project }?.name ?? "—"
        }
        let ids = automation.trigger.projects
        if ids.isEmpty { return String(localized: "All projects") }
        let names = ids.compactMap { id in model.projects.first { $0.id == id }?.name }
        return names.isEmpty ? String(localized: "\(ids.count) projects") : names.joined(separator: ", ")
    }

    @ViewBuilder private var lastRun: some View {
        if let run = automation.lastRun {
            Label(AutomationStatus.relative(run.finishedAt), systemImage: AutomationStatus.symbol(run.status))
                .font(.system(size: 12.5)).foregroundStyle(AutomationStatus.tint(run.status)).lineLimit(1)
                .help(AutomationStatus.lastRun(run))
        } else {
            cell(newKey == nil ? String(localized: "Never") : "—")
        }
    }

    @ViewBuilder private var status: some View {
        if newKey != nil {
            StatusPill(text: String(localized: "Unsaved"), tone: .accent)
        } else {
            HStack(spacing: 6) {
                Circle().fill(automation.mode == .live ? Theme.success : DashboardPalette.ink3).frame(width: 6, height: 6)
                Text(automation.mode == .live ? String(localized: "On") : String(localized: "Off"))
                    .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink2)
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Open") { model.select(key) }
            if let newKey {
                Divider()
                Button("Discard", role: .destructive) { model.discard(newKey) }
            } else {
                Button(automation.mode == .live ? String(localized: "Turn Off") : String(localized: "Turn On")) {
                    Task { await model.setMode(automation.mode == .live ? .off : .live, of: automation.id) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(DashboardPalette.ink3)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "More"))
        .accessibilityIdentifier("automation-row-menu-\(key)")
    }
}

/// Automations were paused with the switch earlier versions had: say so, and offer the way back.
private struct AutomationPausedNotice: View {
    let model: AutomationViewModel
    var body: some View {
        HStack(spacing: 10) {
            Label("Automatic runs are paused. Manual runs are still available.", systemImage: "pause.circle.fill")
                .font(.system(size: 12.5)).foregroundStyle(Theme.warn)
            Spacer()
            Button("Resume") { Task { await model.setPaused(false) } }.controlSize(.small)
                .accessibilityIdentifier("automation-resume")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Nothing open: the templates as a column of cards to start from, and a blank one last.
private struct AutomationEmptyState: View {
    let model: AutomationViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("No automations yet")
                    .font(.system(size: 14)).foregroundStyle(DashboardPalette.ink2)
                    .padding(.bottom, 8)
                Text("A scheduled automation starts an agent with a prompt at the times you choose. An event automation waits for a GitHub or Jira event, checks its filters, then acts. Every template starts Off.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 48)
                if model.settings?.paused == true { AutomationPausedNotice(model: model).padding(.bottom, 20) }
                if let error = model.error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled).padding(.bottom, 20)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Start from a template")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.leading, 4).padding(.bottom, 2)
                    ForEach(model.catalog?.templates ?? []) { template in
                        AutomationTemplateCard(category: model.category(of: template), name: template.localizedName,
                                               summary: template.localizedSummary) {
                            model.create(from: template)
                        }
                        .accessibilityIdentifier("automation-template-\(template.id)")
                    }
                    HStack(spacing: 10) {
                        AutomationAddNewCard(title: String(localized: "New scheduled"), symbol: "clock") { model.create(.schedule) }
                            .accessibilityIdentifier("automation-add-schedule")
                        AutomationAddNewCard(title: String(localized: "New on an event"), symbol: "bolt") { model.create(.event) }
                            .accessibilityIdentifier("automation-add-new")
                    }
                }
            }
            .frame(maxWidth: Theme.Size.readableColumn)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 56).padding(.bottom, 40)
        }
    }
}

/// A template as a card: what sets it off as a small kicker, its name, and what it does.
private struct AutomationTemplateCard: View {
    let category: String
    let name: String
    let summary: String
    let open: () -> Void

    var body: some View {
        AutomationCardButton(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                if !category.isEmpty {
                    Text(category.uppercased())
                        .font(.system(size: 10.5, weight: .medium)).tracking(0.4)
                        .foregroundStyle(DashboardPalette.ink3).lineLimit(1)
                }
                Text(name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(summary).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
    }
}

/// A blank automation of one kind, last under the templates.
private struct AutomationAddNewCard: View {
    let title: String
    let symbol: String
    let open: () -> Void

    var body: some View {
        AutomationCardButton(action: open) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// A full-width card with a hairline border that lightens under the pointer.
private struct AutomationCardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.primary.opacity(0.04) : Color.primary.opacity(0.015), in: shape)
                .overlay(shape.strokeBorder(DashboardPalette.hairline, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A node's kind as a small tinted square: the trigger, a filter or an action.
struct AutomationGlyph: View {
    let symbol: String
    let tone: ThemeTone
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .frame(width: 26, height: 26)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// How modes, run and step statuses read and look, shared by the list, the dry run and history.
enum AutomationStatus {
    static func tone(_ mode: Automation.Mode) -> ThemeTone {
        switch mode {
        case .off: .neutral
        case .live: .success
        }
    }
    static func symbol(_ status: String) -> String {
        switch status {
        case "passed", "completed": "checkmark.circle.fill"
        case "done": "checkmark.seal.fill"
        case "planned": "arrow.right.circle"
        case "failed", "filtered": "line.3.horizontal.decrease.circle"
        case "skipped": "minus.circle"
        case "limited": "hourglass"
        case "launching": "clock.arrow.circlepath"
        default: "exclamationmark.triangle.fill"
        }
    }
    static func tint(_ status: String) -> Color {
        switch status {
        case "passed", "completed", "done": Theme.success
        case "planned", "launching": Theme.accent
        case "failed", "filtered", "skipped": DashboardPalette.ink3
        default: Theme.warn
        }
    }
    static func title(_ status: String) -> String {
        switch status {
        case "passed": String(localized: "Passed")
        case "failed": String(localized: "Stopped here")
        case "planned": String(localized: "Would run")
        case "done": String(localized: "Done")
        case "skipped": String(localized: "Skipped")
        case "completed": String(localized: "Completed")
        case "filtered": String(localized: "Filtered out")
        case "limited": String(localized: "Rate limited")
        case "launching": String(localized: "Starting the agent")
        default: String(localized: "Error")
        }
    }
    static func lastRun(_ run: Automation.RunSummary) -> String {
        "\(title(run.status)) \(relative(run.finishedAt))"
    }
    static func relative(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
