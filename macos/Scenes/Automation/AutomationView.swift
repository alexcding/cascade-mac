import SwiftUI

/// Automation: the defined pipelines down the left, the open one on the right as a page in the
/// Dashboard's style. New sits on the toolbar's leading side and the switch for every automation
/// on its trailing side, so the list holds pipelines and nothing else. Webhook forwarding is under
/// Settings → Integrations.
struct AutomationView: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        // AppKit owns the divider, so a drag resizes the list without re-rendering the editor per frame.
        HSplitView {
            AutomationListPane(model: model)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 480)
            Group {
                if model.draft != nil {
                    AutomationEditorView(model: model)
                } else if model.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AutomationEmptyState(model: model)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paneBackground)
        .accessibilityIdentifier("automation-screen")
        .toolbar {
            // New sits where a page title would, over the list it adds to; the page carries its own title.
            ToolbarItem(placement: .navigation) { AutomationNewMenu(model: model) }
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            ToolbarItem(placement: .primaryAction) { AutomationMasterSwitch(model: model) }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }
}

/// Every automation on or paused at once; the one switch that outranks each pipeline's own mode.
private struct AutomationMasterSwitch: View {
    let model: AutomationViewModel
    private var on: Bool { !(model.settings?.paused ?? false) }

    var body: some View {
        HStack(spacing: 8) {
            Text(on ? "Automations on" : "Automations paused")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? Color.primary : Theme.warn)
            Toggle("All automations", isOn: Binding(get: { on }, set: { value in Task { await model.setPaused(!value) } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .accessibilityIdentifier("automation-pause")
        }
        .padding(.horizontal, 10)
        .disabled(model.settings == nil)
        .help(on ? "Pause every automation. Pipelines keep their modes and resume where they were."
                 : "Paused: no pipeline runs until you switch automations back on.")
    }
}

/// "+" at the toolbar's leading edge: a blank pipeline or one of the catalogue's templates.
struct AutomationNewMenu: View {
    let model: AutomationViewModel
    var body: some View {
        Menu {
            Button("Blank Automation") { model.create() }
            if let templates = model.catalog?.templates, !templates.isEmpty {
                Divider()
                Section("Start From") {
                    ForEach(templates) { template in
                        Button(template.name) { model.create(from: template) }
                    }
                }
            }
        } label: {
            Label("New Automation", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("New automation")
        .accessibilityIdentifier("automation-new")
    }
}

/// The defined pipelines, and a new one at the bottom while it is being written.
private struct AutomationListPane: View {
    let model: AutomationViewModel

    var body: some View {
        // A List for the system's own separators between pipelines; each row still draws its
        // own selection, since the editor, not the list, owns which pipeline is open.
        List {
            ForEach(model.automations) { automation in
                let selected = model.selectedID == automation.id
                // The open pipeline's row follows its draft, so a rename shows as it is typed.
                let shown = selected ? (model.draft ?? automation) : automation
                AutomationListRow(name: shown.name, summary: shown.summary(model.catalog),
                                  pill: (shown.mode.label, AutomationStatus.tone(shown.mode)),
                                  lastRun: automation.lastRun, selected: selected,
                                  edited: model.hasUnsavedEdits(automation.id)) {
                    model.select(automation.id)
                }
                .accessibilityIdentifier("automation-row-\(automation.id)")
                .automationListRow()
            }
            // Last, where they land once saved: a new pipeline takes the next position.
            ForEach(model.newDrafts, id: \.key) { item in
                AutomationListRow(name: item.draft.name, summary: item.draft.summary(model.catalog),
                                  pill: ("Unsaved", .accent), lastRun: nil, selected: model.openKey == item.key) {
                    model.select(item.key)
                }
                .accessibilityIdentifier("automation-row-\(item.key)")
                .automationListRow()
            }
            if model.automations.isEmpty && model.newKeys.isEmpty && !model.loading {
                Text("No automations yet. Use + to start one.")
                    .font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                    .padding(.horizontal, 10).padding(.vertical, 14)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("automation-list")
    }
}

private extension View {
    /// A pipeline's row in the list: the row keeps its own padding, and asks for the separators.
    func automationListRow() -> some View {
        listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
            .listRowSeparator(.visible)
            .listRowBackground(Color.clear)
    }
}

private struct AutomationListRow: View {
    let name: String
    let summary: String
    let pill: (text: String, tone: ThemeTone)
    let lastRun: Automation.RunSummary?
    let selected: Bool
    var edited = false
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name.isEmpty ? "Untitled automation" : name)
                        .font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    if edited {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .help("Edited, not saved").accessibilityLabel("Edited, not saved")
                    }
                    Spacer(minLength: 6)
                    StatusPill(text: pill.text, tone: pill.tone)
                }
                Text(summary).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let run = lastRun {
                    Label(AutomationStatus.lastRun(run), systemImage: AutomationStatus.symbol(run.status))
                        .font(.system(size: 11.5)).foregroundStyle(AutomationStatus.tint(run.status)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        selected ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear
    }
}

/// Nothing open: what a pipeline is, and the templates as tiles to start from.
private struct AutomationEmptyState: View {
    let model: AutomationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardPageHeader(caption: "Pipelines across your projects", title: "Automation")
                    .padding(.top, 12).padding(.bottom, 12)
                Text("A pipeline waits for a GitHub or Jira event, checks its filters, then acts. Dry-run it on a real pull request to see exactly what it would do, then switch it on.")
                    .font(.system(size: 13)).foregroundStyle(DashboardPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 36)
                if let error = model.error {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled).padding(.bottom, 20)
                }
                DashboardSectionHeader(title: "Start from", detail: "Every template starts Off")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], alignment: .leading, spacing: 14) {
                    AutomationTemplateTile(name: "Blank automation", summary: "A trigger and nothing else; add the filters and actions you need.",
                                           symbol: "plus") { model.create() }
                    ForEach(model.catalog?.templates ?? []) { template in
                        AutomationTemplateTile(name: template.name, summary: template.summary, symbol: "bolt") {
                            model.create(from: template)
                        }
                    }
                }
            }
            .frame(maxWidth: Theme.Size.readableColumn + 200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
        }
    }
}

private struct AutomationTemplateTile: View {
    let name: String
    let summary: String
    let symbol: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                AutomationGlyph(symbol: symbol, tone: .accent)
                Text(name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(summary).font(.system(size: 12)).foregroundStyle(DashboardPalette.ink3)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(hovering ? Color.primary.opacity(0.03) : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        default: "exclamationmark.triangle.fill"
        }
    }
    static func tint(_ status: String) -> Color {
        switch status {
        case "passed", "completed", "done": Theme.success
        case "planned": Theme.accent
        case "failed", "filtered", "skipped": DashboardPalette.ink3
        default: Theme.warn
        }
    }
    static func title(_ status: String) -> String {
        switch status {
        case "passed": "Passed"
        case "failed": "Stopped here"
        case "planned": "Would run"
        case "done": "Done"
        case "skipped": "Skipped"
        case "completed": "Completed"
        case "filtered": "Filtered out"
        case "limited": "Rate limited"
        default: "Error"
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
