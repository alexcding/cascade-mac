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
                if model.panel == .editor {
                    Divider()
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
            Text(model.draft?.mode == .live ? String(localized: "On") : String(localized: "Off")).font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.draft?.mode == .live ? Theme.success : DashboardPalette.ink3)
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
                Picker("Agent", selection: value(\.cli)) {
                    ForEach(SessionAgent.allCases.filter { $0.driver != nil }) { agent in
                        Text(agent.label).tag(agent.rawValue)
                    }
                }
                .labelsHidden()
            }
            section(String(localized: "Project")) {
                Picker("Project", selection: value(\.project)) {
                    if !model.projects.contains(where: { $0.id == schedule.project }) {
                        Text("Choose a project").tag(schedule.project)
                    }
                    ForEach(model.projects) { project in Text(project.name).tag(project.id) }
                }
                .labelsHidden()
            }
            section(String(localized: "Workspace"),
                    help: String(localized: "New run: a new branch and worktree for every run. Worktree: every run works in the worktree of the branch you name.")) {
                Picker("Workspace", selection: value(\.workspace)) {
                    Text("New run").tag(Automation.Schedule.Workspace.new)
                    Text("Worktree").tag(Automation.Schedule.Workspace.worktree)
                }
                .pickerStyle(.segmented).labelsHidden()
                if schedule.workspace == .worktree {
                    TextField("Branch", text: value(\.branch), prompt: Text("main"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("automation-branch")
                }
            }
            section(String(localized: "Session"),
                    help: String(localized: "Fresh: each run starts a new conversation. Reuse: each run continues the last run’s session and conversation.")) {
                Picker("Session", selection: value(\.session)) {
                    Text("Fresh").tag(Automation.Schedule.Session.fresh)
                    Text("Reuse").tag(Automation.Schedule.Session.reuse)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            section(String(localized: "Schedule")) {
                Picker("Schedule", selection: value(\.repeat)) {
                    ForEach(Automation.Schedule.Repeat.allCases, id: \.self) { item in
                        Text(Automation.Schedule.label(item)).tag(item)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("automation-repeat")
                times
            }
            section(String(localized: "Grace"),
                    help: String(localized: "A run missed while the Mac slept or Cascade was closed still starts if it is no later than this. Only the latest missed run starts.")) {
                Picker("Grace", selection: value(\.graceMinutes)) {
                    if !Automation.Schedule.graceChoices.contains(where: { $0.minutes == schedule.graceMinutes }) {
                        Text("\(schedule.graceMinutes) minutes").tag(schedule.graceMinutes)
                    }
                    ForEach(Automation.Schedule.graceChoices, id: \.minutes) { choice in Text(choice.label).tag(choice.minutes) }
                }
                .labelsHidden()
            }
            precheck
        }
    }

    @ViewBuilder private var times: some View {
        switch schedule.repeat {
        case .cron:
            TextField("Cron", text: value(\.cron), prompt: Text("0 9 * * 1-5"))
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                .accessibilityIdentifier("automation-cron")
            Text("Minute, hour, day, month, weekday, in local time.")
                .font(.system(size: 11)).foregroundStyle(DashboardPalette.ink3)
        default:
            if schedule.repeat == .weekly { AutomationWeekdays(days: value(\.days)) }
            if schedule.repeat == .hours {
                Stepper(value: value(\.everyHours), in: 1...24) {
                    Text(schedule.everyHours == 1 ? String(localized: "Every hour") : String(localized: "Every \(schedule.everyHours) hours"))
                        .font(.system(size: 12.5))
                }
            }
            HStack {
                Text(schedule.repeat == .hours ? String(localized: "Starting at") : String(localized: "Time"))
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.ink2)
                Spacer()
                DatePicker("Time", selection: value(\.timeOfDay), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field)
                    .accessibilityIdentifier("automation-time")
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
                Picker("Timeout", selection: value(\.precheckTimeout)) {
                    if !Automation.Schedule.timeoutChoices.contains(where: { $0.seconds == schedule.precheckTimeout }) {
                        Text("\(schedule.precheckTimeout) sec").tag(schedule.precheckTimeout)
                    }
                    ForEach(Automation.Schedule.timeoutChoices, id: \.seconds) { choice in Text(choice.label).tag(choice.seconds) }
                }
                .labelsHidden().fixedSize()
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
