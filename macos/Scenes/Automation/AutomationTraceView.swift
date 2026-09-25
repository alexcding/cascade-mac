import SwiftUI

/// Test the open draft against a real PR or ticket: what matched, what stopped it, and the
/// exact commands a live run would send.
struct AutomationDryRunSheet: View {
    @Bindable var model: AutomationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dry Run").font(.system(size: 20, weight: .bold)).tracking(-0.4)
                Text("Plans every step against a sample. Lookups run; nothing is written.")
                    .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3)
            }
            .padding(.bottom, 18)
            HStack(spacing: 10) {
                Picker(model.sampleKind == "jira" ? String(localized: "Ticket") : String(localized: "Pull request"), selection: $model.sample) {
                    if model.samples.isEmpty { Text(model.samplesLoading ? String(localized: "Loading…") : String(localized: "None synced")).tag(AutomationSample?.none) }
                    ForEach(model.samples) { sample in
                        Text(sample.detail.map { "\(sample.label) — \($0)" } ?? sample.label).tag(Optional(sample))
                    }
                }
                .frame(maxWidth: 440)
                .accessibilityIdentifier("automation-sample")
                DashboardRefreshButton(name: String(localized: "samples"), id: "automation-samples", busy: model.samplesLoading) { model.loadSamples() }
            }
            if let types = model.draft?.trigger.types, types.count > 1 {
                Picker("As if", selection: Binding(get: { model.sampleEvent ?? types.first ?? "" }, set: { model.sampleEvent = $0 })) {
                    ForEach(types, id: \.self) { Text(model.catalog?.trigger($0)?.localizedLabel ?? $0).tag($0) }
                }
                .frame(maxWidth: 320)
                .padding(.top, 10)
            }
            if let error = model.samplesError {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled).padding(.top, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.dryRunning { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30) }
                    if let error = model.dryRunError {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.warn).textSelection(.enabled)
                    }
                    if let trace = model.trace { AutomationTraceSteps(trace: trace) }
                    else if !model.dryRunning && model.dryRunError == nil {
                        Text("Choose a sample and run.").font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DashboardPalette.hairline, lineWidth: 1))
            .padding(.vertical, 18)
            HStack {
                Button("Run for Real…") { confirmLive = true }
                    .disabled(model.sample == nil || model.isNew || model.dirty || model.dryRunning)
                    .help(model.dirty || model.isNew ? String(localized: "Save first to run for real.") : String(localized: "Execute the actions on this sample now."))
                Spacer()
                Button("Close") { model.clearTrace(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Dry Run") { Task { await model.dryRun() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.sample == nil || model.dryRunning)
                    .accessibilityIdentifier("automation-dry-run-go")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 660, height: 580)
        .confirmationDialog("Run this automation for real?", isPresented: $confirmLive) {
            Button("Run Now", role: .destructive) { Task { await model.runNow() } }
        } message: {
            Text("Its actions act on \(model.sample?.label ?? String(localized: "the sample")) as you, even while it is off.")
        }
    }
}

/// A trace, step by step: the trigger, then each filter and action with its outcome and commands.
struct AutomationTraceSteps: View {
    let trace: AutomationTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(symbol: trace.triggerMatched ? "bolt.fill" : "bolt.slash", tint: trace.triggerMatched ? Theme.accent : Theme.warn,
                title: trace.triggerMatched ? String(localized: "Trigger matches") : String(localized: "Trigger would not fire"), detail: trace.triggerDetail, commands: [])
            ForEach(trace.steps) { step in
                row(symbol: AutomationStatus.symbol(step.status), tint: AutomationStatus.tint(step.status),
                    title: AutomationCatalogText.localized(step.label), status: AutomationStatus.title(step.status), detail: step.detail, commands: step.commands)
            }
            if trace.status == "limited" {
                Label("Held back: this automation already ran 30 times in the last hour.", systemImage: "hourglass")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.warn)
            }
        }
        .textSelection(.enabled)
    }

    private func row(symbol: String, tint: Color, title: String, status: String? = nil, detail: String, commands: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if let status { Text(status).font(.system(size: 12, weight: .medium)).foregroundStyle(tint) }
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(commands, id: \.self) { command in
                    Text(command).font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}

/// Recorded automatic and manual runs of the open pipeline, as a ruled list; a row opens to
/// its trace.
struct AutomationRunsView: View {
    let model: AutomationViewModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: String(localized: "Runs"), detail: model.runs.isEmpty ? String(localized: "Automatic and manual runs") : String(localized: "\(model.runs.count) recorded, newest first"),
                                   refresh: model.loadRuns, busy: model.runsLoading, id: "automation-runs")
            if model.runs.isEmpty && !model.runsLoading {
                Text("No runs yet. They appear here once the automation is on and an event matches its trigger, or after Run for Real.")
                    .font(Theme.Typography.emptyHint).foregroundStyle(DashboardPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
            }
            ForEach(Array(model.runs.enumerated()), id: \.element.id) { index, run in
                let open = expanded.contains(run.id)
                Button {
                    if open { expanded.remove(run.id) } else { expanded.insert(run.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: AutomationStatus.symbol(run.status)).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AutomationStatus.tint(run.status)).frame(width: 13)
                        Text(run.subject).font(.system(size: 13.5)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(AutomationStatus.title(run.status)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AutomationStatus.tint(run.status))
                        Text(AutomationStatus.relative(run.finishedAt)).font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DashboardPalette.ink3).fixedSize()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DashboardPalette.ink3).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .modifier(DashboardHoverRow(first: index == 0))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("automation-run-\(run.id)")
                if open {
                    AutomationTraceSteps(trace: run)
                        .padding(.horizontal, 31).padding(.vertical, 16)
                        .overlay(alignment: .bottom) { Rectangle().fill(DashboardPalette.hairline).frame(height: 1) }
                }
            }
        }
        .accessibilityIdentifier("automation-runs")
    }
}
