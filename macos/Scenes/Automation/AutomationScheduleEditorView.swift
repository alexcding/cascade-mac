import SwiftUI

/// A scheduled automation as a page: its name and the prompt the agent starts with on the left,
/// and on the right where the agent works and when, in a column of its own. Runs, saving and
/// Run Now sit in the bar along the bottom, as the pipeline editor's do.
struct AutomationScheduleEditorView: View {
    @Bindable var model: AutomationViewModel
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 16)
                    if !model.isNew { AutomationPanelTabs(selection: $model.panel, editorLabel: String(localized: "Schedule")).padding(.bottom, 20) }
                    if model.panel == .runs {
                        ScrollView { AutomationRunsView(model: model) }
                    } else {
                        prompt
                    }
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // No rule beside the column: the toolbar draws none over it, so one would start
                // from nowhere. Its own fill sets it apart.
                if model.panel == .editor {
                    ScrollView { AutomationScheduleSettings(model: model).padding(20) }
                        .frame(width: 320)
                        .background(Color.primary.opacity(0.015))
                }
            }
            footer
        }
        .confirmationDialog("Delete this automation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("Existing Activity entries are kept. Sessions its runs started stay.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold)).tracking(-0.6)
                .accessibilityIdentifier("automation-name")
                .layoutPriority(1)
            Spacer(minLength: 12)
            AutomationModeLabel(live: model.draft?.mode == .live)
            Toggle(String(localized: "On"), isOn: Binding(
                get: { model.draft?.mode == .live },
                set: { on in Task { await model.setMode(on ? .live : .off) } }))
                .toggleStyle(.switch).labelsHidden()
                .help("On: starts the agent at the scheduled times while Cascade is open.")
                .accessibilityIdentifier("automation-mode")
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutomationSectionLabel(text: String(localized: "Prompt"))
            PlainTextEditor(text: Binding(get: { model.draft?.schedule.prompt ?? "" }, set: { model.draft?.schedule.prompt = $0 }),
                            font: .monospacedSystemFont(ofSize: 13, weight: .regular), inset: NSSize(width: 10, height: 10))
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if model.draft?.schedule.prompt.isEmpty != false {
                        Text("Run the weekly dependency audit and summarize risky changes.")
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(DashboardPalette.ink3)
                            .padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("automation-prompt")
            Text("The agent starts with this, as if typed at its prompt: skills, file paths and slash commands work.")
                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.ink3)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Button(model.isNew ? String(localized: "Discard") : String(localized: "Delete…"), role: .destructive) {
                if model.isNew { model.revert() } else { confirmDelete = true }
            }
            .disabled(model.saving)
            if !model.isNew {
                Button("Revert", action: model.revert).disabled(!model.dirty || model.saving)
                Button("Run Now") { Task { await model.runScheduled() } }
                    .disabled(model.dirty || model.dryRunning || model.saving)
                    .help(model.dirty ? String(localized: "Save before running.") : String(localized: "Start a run now, outside the schedule."))
                    .accessibilityIdentifier("automation-run-now")
            }
            if model.saving || model.dryRunning { ProgressView().controlSize(.small) }
            Button(model.isNew ? String(localized: "Create") : String(localized: "Save")) { Task { await model.save() } }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canSave)
                .accessibilityIdentifier("automation-save")
        }
        .controlSize(.large)
        .padding(.horizontal, 28).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(DashboardPalette.hairline).frame(height: 1) }
    }

    @ViewBuilder private var status: some View {
        if let error = model.error ?? model.dryRunError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled).lineLimit(2)
        } else if let trace = model.trace {
            Label(trace.status == "completed" ? String(localized: "Agent started") : AutomationStatus.title(trace.status),
                  systemImage: AutomationStatus.symbol(trace.status))
                .font(.system(size: 12.5)).foregroundStyle(AutomationStatus.tint(trace.status))
                .help(trace.steps.map { "\($0.label): \($0.detail)" }.joined(separator: "\n"))
        } else if model.saved && !model.dirty {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5)).foregroundStyle(Theme.success)
                .accessibilityIdentifier("automation-saved")
        } else if model.isNew {
            Label("Once on, runs at its times while Cascade is open.", systemImage: "clock")
                .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
        } else if model.dirty {
            Text("Unsaved changes").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
        }
    }
}

/// The right-hand column: the agent, the project, where it works, and when.
private struct AutomationScheduleSettings: View {
    let model: AutomationViewModel

    private var schedule: Automation.Schedule { model.draft?.schedule ?? Automation.Schedule() }

    private func value<T>(_ path: WritableKeyPath<Automation.Schedule, T>) -> Binding<T> {
        Binding(get: { schedule[keyPath: path] }, set: { model.draft?.schedule[keyPath: path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(String(localized: "Agent")) {
                ThemedChoice(title: String(localized: "Agent"),
                             options: SessionAgent.allCases.filter { $0.driver != nil }.map { ThemedOption($0.rawValue, $0.label) },
                             selection: value(\.cli))
            }
            section(String(localized: "Project")) {
                ThemedChoice(title: String(localized: "Project"), options: model.projects.map { ThemedOption($0.id, $0.name) },
                             selection: value(\.project), placeholder: String(localized: "Choose a project"))
            }
            section(String(localized: "Workspace"),
                    help: String(localized: "New run: a new branch and worktree for every run. Worktree: every run works in the worktree of the branch you name.")) {
                ThemedSegments(options: [ThemedOption(Automation.Schedule.Workspace.new, String(localized: "New run")),
                                         ThemedOption(Automation.Schedule.Workspace.worktree, String(localized: "Worktree"))],
                               selection: value(\.workspace), id: "automation-workspace")
                if schedule.workspace == .worktree {
                    TextField("Branch", text: value(\.branch), prompt: Text("main"))
                        .font(.system(size: 13)).themedField()
                        .accessibilityIdentifier("automation-branch")
                }
            }
            section(String(localized: "Session"),
                    help: String(localized: "Fresh: each run starts a new conversation. Reuse: each run continues the last run’s session and conversation.")) {
                ThemedSegments(options: [ThemedOption(Automation.Schedule.Session.fresh, String(localized: "Fresh")),
                                         ThemedOption(Automation.Schedule.Session.reuse, String(localized: "Reuse"))],
                               selection: value(\.session), id: "automation-session")
            }
            section(String(localized: "Schedule")) {
                ThemedChoice(title: String(localized: "Schedule"),
                             options: Automation.Schedule.Repeat.allCases.map { ThemedOption($0, Automation.Schedule.label($0)) },
                             selection: value(\.repeat))
                    .accessibilityIdentifier("automation-repeat")
                times
            }
            section(String(localized: "Grace"),
                    help: String(localized: "A run missed while the Mac slept or Cascade was closed still starts if it is no later than this. Only the latest missed run starts.")) {
                ThemedChoice(title: String(localized: "Grace"), options: graceOptions, selection: value(\.graceMinutes))
            }
            precheck
        }
    }

    @ViewBuilder private var times: some View {
        switch schedule.repeat {
        case .cron:
            TextField("Cron", text: value(\.cron), prompt: Text("0 9 * * 1-5"))
                .font(.system(size: 12.5, design: .monospaced)).themedField()
                .accessibilityIdentifier("automation-cron")
            Text("Minute, hour, day, month, weekday, in local time.")
                .font(.system(size: 11)).foregroundStyle(DashboardPalette.ink3)
        default:
            if schedule.repeat == .weekly { AutomationWeekdays(days: value(\.days)) }
            if schedule.repeat == .hours {
                ThemedChoice(title: String(localized: "Every"),
                             options: everyHoursOptions, selection: value(\.everyHours))
                    .accessibilityIdentifier("automation-every-hours")
            }
            HStack {
                Text(schedule.repeat == .hours ? String(localized: "Starting at") : String(localized: "Time"))
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink2)
                Spacer()
                HStack(spacing: 4) {
                    ThemedChoice(title: String(localized: "Hour"), options: Self.hourOptions, selection: value(\.hour))
                        .frame(width: 92)
                        .accessibilityIdentifier("automation-time")
                    ThemedChoice(title: String(localized: "Minute"), options: Self.minuteOptions, selection: value(\.minute))
                        .frame(width: 64)
                        .accessibilityIdentifier("automation-minute")
                }
            }
        }
    }

    private var precheck: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AutomationSectionLabel(text: String(localized: "Precheck"),
                                       help: String(localized: "A zsh script run in the project folder before each run. A non-zero exit skips the run; what it prints is added under the prompt."))
                Spacer()
                Text("Timeout").font(.system(size: 10.5, weight: .medium)).textCase(.uppercase).tracking(0.5)
                    .foregroundStyle(DashboardPalette.ink3)
                ThemedChoice(title: String(localized: "Timeout"), options: timeoutOptions, selection: value(\.precheckTimeout))
                    .frame(width: 110)
            }
            PlainTextEditor(text: value(\.precheck), font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                .frame(height: 84)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if schedule.precheck.isEmpty {
                        Text("gh pr list --json number -q '.[0].number'")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(DashboardPalette.ink3)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("automation-precheck")
        }
    }

    /// Every 1 to 24 hours, and the schedule's own interval when it is none of them.
    private var everyHoursOptions: [ThemedOption<Int>] {
        let label = { (hours: Int) in hours == 1 ? String(localized: "Every hour") : String(localized: "Every \(hours) hours") }
        let choices = (1...24).map { ThemedOption($0, label($0)) }
        return (1...24).contains(schedule.everyHours) ? choices : [ThemedOption(schedule.everyHours, label(schedule.everyHours))] + choices
    }

    /// The grace choices, and the schedule's own when it is none of them.
    private var graceOptions: [ThemedOption<Int>] {
        let choices = Automation.Schedule.graceChoices.map { ThemedOption($0.minutes, $0.label) }
        return choices.contains { $0.value == schedule.graceMinutes } ? choices
            : [ThemedOption(schedule.graceMinutes, String(localized: "\(schedule.graceMinutes) minutes"))] + choices
    }

    /// The timeout choices, and the schedule's own when it is none of them.
    private var timeoutOptions: [ThemedOption<Int>] {
        let choices = Automation.Schedule.timeoutChoices.map { ThemedOption($0.seconds, $0.label) }
        return choices.contains { $0.value == schedule.precheckTimeout } ? choices
            : [ThemedOption(schedule.precheckTimeout, String(localized: "\(schedule.precheckTimeout) sec"))] + choices
    }

    /// Every hour of the day, as the user's clock writes it (9 AM, or 09): each formatted on a
    /// fixed day in GMT, which no daylight-saving change skips, and again whenever it is drawn, so a
    /// change of locale or of 12- or 24-hour time shows.
    private static var hourOptions: [ThemedOption<Int>] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let style = Date.FormatStyle(timeZone: .gmt).hour()
        return (0..<24).map { hour in
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)) ?? Date()
            return ThemedOption(hour, date.formatted(style))
        }
    }

    private static let minuteOptions: [ThemedOption<Int>] = (0..<60).map { ThemedOption($0, String(format: "%02d", $0)) }

    private func section<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AutomationSectionLabel(text: title, help: help)
            content()
        }
    }
}

/// A small uppercase label over a group of fields, with an info mark when it has more to say.
struct AutomationSectionLabel: View {
    let text: String
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(text).textCase(.uppercase)
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(DashboardPalette.ink3)
            if let help {
                Image(systemName: "info.circle").font(.system(size: 10.5)).foregroundStyle(DashboardPalette.ink3)
                    .help(help).accessibilityLabel(help)
            }
        }
    }
}

/// The days a weekly schedule runs on, Monday first, as toggles.
private struct AutomationWeekdays: View {
    @Binding var days: [Int]

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.removeAll { $0 == day } } else { days = (days + [day]).sorted() }
                } label: {
                    Text(symbols[day % 7]).font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                        .background(on ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(on ? Color.primary : DashboardPalette.hairline, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day % 7])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
