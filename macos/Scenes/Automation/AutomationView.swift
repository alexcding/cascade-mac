import SwiftUI

/// Automation: pipelines on the left, the open one on the right.
struct AutomationView: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        HStack(spacing: 0) {
            AutomationListPane(model: model)
                .frame(width: 290)
            Divider()
            Group {
                if model.draft != nil {
                    AutomationEditorView(model: model)
                } else if model.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AutomationEmptyState(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("automation-screen")
        .toolbar {
            PageTitleToolbarItem(title: "Automation")
            ToolbarItem(placement: .primaryAction) { AutomationNewMenu(model: model) }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }
}

/// "+" in the toolbar: a blank pipeline or one of the catalogue's templates.
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
        .help("New automation")
        .accessibilityIdentifier("automation-new")
    }
}

private struct AutomationListPane: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        VStack(spacing: 0) {
            AutomationStatusHeader(model: model)
            Divider()
            if model.automations.isEmpty && !model.loading {
                Text("No automations yet. Use + to start from a template.")
                    .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })) {
                    ForEach(model.automations) { automation in
                        AutomationRow(automation: automation, catalog: model.catalog).tag(automation.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("automation-list")
            }
        }
    }
}

private struct AutomationStatusHeader: View {
    @Bindable var model: AutomationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pause all automations", isOn: Binding(
                get: { model.settings?.paused ?? false },
                set: { value in Task { await model.setPaused(value) } }))
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier("automation-pause")
            Toggle("Forward GitHub webhooks", isOn: Binding(
                get: { model.settings?.forwardWebhooks ?? true },
                set: { value in Task { await model.setForwarding(value) } }))
                .toggleStyle(.switch).controlSize(.small)
                .help("Deliver PR events the moment they happen instead of on the next poll. Needs the gh webhook extension.")
            if let settings = model.settings {
                Text(forwardingText(settings)).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func forwardingText(_ settings: AutomationSettings) -> String {
        if settings.paused { return "Paused: no pipeline runs until you resume." }
        guard settings.forwardWebhooks else { return "Polling only." }
        if settings.forwardable.isEmpty { return "No live PR pipeline needs forwarding." }
        let running = settings.forwardable.filter(settings.forwarding.contains)
        return running.count == settings.forwardable.count
            ? "Forwarding \(running.count) repo\(running.count == 1 ? "" : "s")."
            : "Forwarding \(running.count) of \(settings.forwardable.count) repos. Polling covers the rest."
    }
}

private struct AutomationRow: View {
    let automation: Automation
    let catalog: AutomationCatalog?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(automation.name.isEmpty ? "Untitled automation" : automation.name).lineLimit(1)
                Spacer(minLength: 4)
                AutomationModeBadge(mode: automation.mode)
            }
            Text(automation.summary(catalog)).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            if let run = automation.lastRun {
                Label(AutomationStatus.lastRun(run), systemImage: AutomationStatus.symbol(run.status))
                    .font(.caption2).foregroundStyle(AutomationStatus.tint(run.status)).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AutomationModeBadge: View {
    let mode: Automation.Mode
    var body: some View {
        Text(mode.label)
            .font(Theme.Typography.pill).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(background, in: Capsule())
    }
    private var tint: Color {
        switch mode {
        case .off: Theme.textTertiary
        case .shadow: Theme.warn
        case .live: Theme.success
        }
    }
    private var background: Color {
        switch mode {
        case .off: Theme.surfaceHover
        case .shadow: Theme.warnBackground
        case .live: Theme.successBackground
        }
    }
}

private struct AutomationEmptyState: View {
    let model: AutomationViewModel
    var body: some View {
        VStack(spacing: 14) {
            Text("Automate across projects").font(Theme.Typography.emptyTitle)
            Text("A pipeline waits for a GitHub or Jira event, checks your filters, then acts. Start one from a template, dry-run it on a real PR, then switch it to Shadow or Live.")
                .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if let templates = model.catalog?.templates {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(templates.prefix(6)) { template in
                        Button { model.create(from: template) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(template.name)
                                Text(template.summary).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: 420)
            }
            if let error = model.error { Text(error).foregroundStyle(Theme.warn).textSelection(.enabled) }
        }
        .padding(28)
    }
}

/// How run and step statuses read and look, shared by the list, the dry run and history.
enum AutomationStatus {
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
        case "failed", "filtered", "skipped": Theme.textSecondary
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
        let when = relative(run.finishedAt)
        let mode = run.mode == "shadow" ? " (shadow)" : ""
        return "\(title(run.status))\(mode) \(when)"
    }
    static func relative(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
