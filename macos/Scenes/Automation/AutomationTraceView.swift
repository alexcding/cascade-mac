import SwiftUI

/// Test the open draft against a real PR or ticket: what matched, what stopped it, and the
/// exact commands a live run would send.
struct AutomationDryRunSheet: View {
    @Bindable var model: AutomationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dry Run").font(.title3)
            Text("Plans every step against the sample. Lookups run; nothing is written.")
                .font(.callout).foregroundStyle(Theme.textSecondary)
            HStack {
                Picker(model.sampleKind == "jira" ? "Ticket" : "Pull request", selection: $model.sample) {
                    if model.samples.isEmpty { Text(model.samplesLoading ? "Loading…" : "None synced").tag(AutomationSample?.none) }
                    ForEach(model.samples) { sample in
                        Text(sample.detail.map { "\(sample.label) — \($0)" } ?? sample.label).tag(Optional(sample))
                    }
                }
                .frame(maxWidth: 460)
                .accessibilityIdentifier("automation-sample")
                Button { model.loadSamples() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload samples")
                if model.samplesLoading { ProgressView().controlSize(.small) }
            }
            if let types = model.draft?.trigger.types, types.count > 1 {
                Picker("As if", selection: Binding(get: { model.sampleEvent ?? types.first ?? "" }, set: { model.sampleEvent = $0 })) {
                    ForEach(types, id: \.self) { Text(model.catalog?.trigger($0)?.label ?? $0).tag($0) }
                }
                .frame(maxWidth: 320)
            }
            if let error = model.samplesError { Text(error).foregroundStyle(Theme.warn).textSelection(.enabled) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.dryRunning { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.dryRunError { Text(error).foregroundStyle(Theme.warn).textSelection(.enabled) }
                    if let trace = model.trace { AutomationTraceSteps(trace: trace) }
                    else if !model.dryRunning && model.dryRunError == nil {
                        Text("Choose a sample and run.").foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            HStack {
                Button("Run for Real…") { confirmLive = true }
                    .disabled(model.sample == nil || model.isNew || model.dirty || model.dryRunning)
                    .help(model.dirty || model.isNew ? "Save first to run for real." : "Execute the actions on this sample now.")
                Spacer()
                Button("Close") { model.clearTrace(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Dry Run") { Task { await model.dryRun() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.sample == nil || model.dryRunning)
                    .accessibilityIdentifier("automation-dry-run-go")
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .confirmationDialog("Run this automation for real?", isPresented: $confirmLive) {
            Button("Run Now", role: .destructive) { Task { await model.runNow() } }
        } message: {
            Text("Its actions act on \(model.sample?.label ?? "the sample") as you, whatever its mode.")
        }
    }
}

/// A trace, step by step.
struct AutomationTraceSteps: View {
    let trace: AutomationTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(symbol: trace.triggerMatched ? "bolt.fill" : "bolt.slash", tint: trace.triggerMatched ? Theme.accent : Theme.warn,
                title: trace.triggerMatched ? "Trigger matches" : "Trigger would not fire", detail: trace.triggerDetail, commands: [])
            ForEach(trace.steps) { step in
                row(symbol: AutomationStatus.symbol(step.status), tint: AutomationStatus.tint(step.status),
                    title: "\(step.label) — \(AutomationStatus.title(step.status))", detail: step.detail, commands: step.commands)
            }
            if trace.status == "limited" {
                Text("Held back: this automation already ran \(30) times in the last hour.").foregroundStyle(Theme.warn)
            }
        }
        .textSelection(.enabled)
    }

    private func row(symbol: String, tint: Color, title: String, detail: String, commands: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(Theme.textSecondary) }
                ForEach(commands, id: \.self) { command in
                    Text(command).font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

/// Recorded shadow, live and manual runs of the open pipeline.
struct AutomationRunsView: View {
    let model: AutomationViewModel

    var body: some View {
        Group {
            if model.runsLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.runs.isEmpty {
                Text("No runs yet. Runs appear here once the automation is in Shadow or Live and an event matches its trigger.")
                    .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.runs) { run in
                    DisclosureGroup {
                        AutomationTraceSteps(trace: run).padding(.vertical, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: AutomationStatus.symbol(run.status)).foregroundStyle(AutomationStatus.tint(run.status))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(run.subject).lineLimit(1)
                                Text("\(AutomationStatus.title(run.status)) · \(run.mode) · \(AutomationStatus.relative(run.finishedAt))")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("automation-runs")
            }
        }
    }
}
