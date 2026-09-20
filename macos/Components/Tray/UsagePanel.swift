import SwiftUI

struct UsagePanel: View {
    let shell: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The agent is chosen in the app (the toolbar's usage picker).
            Text(shell.usageAgent == "codex" ? "Codex usage" : "Claude usage").font(.headline)
            if shell.usageLoading && shell.usage == nil {
                ProgressView("Loading usage…").controlSize(.small)
            }
            if let error = shell.usageError { Text(error).font(.caption).foregroundStyle(.orange) }
            let snapshot = shell.usage
            let agent = shell.usageAgent == "codex" ? snapshot?.codex : snapshot?.claude
            let limits = shell.usageAgent == "codex" ? snapshot?.codexLimits : snapshot?.limits
            if let agent {
                Text("Today: \(agent.tokens.formatted(.number.precision(.fractionLength(0)))) tokens · \(agent.cost.formatted(.currency(code: "USD")))")
                    .font(.callout).monospacedDigit()
            }
            if let session = limits?.session { usageWindow("Session", window: session, duration: 5 * 3600) }
            if let weekly = limits?.weekly { usageWindow("Weekly", window: weekly, duration: 7 * 86400) }
            if let scoped = limits?.scoped {
                ForEach(Array(scoped.enumerated()), id: \.offset) { _, window in
                    usageWindow("\(window.label ?? "Model") · Weekly", window: window, duration: 7 * 86400)
                }
            }
            if agent == nil && limits == nil && !shell.usageLoading {
                Text("Usage is unavailable").font(.callout).foregroundStyle(.secondary)
            }
            if let asOf = snapshot?.asOf, let date = backendTimestamp(asOf) {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Each agent's own accent: Claude coral, Codex periwinkle.
    private var barColor: Color {
        shell.usageAgent == "codex" ? Color(red: 0x71 / 255, green: 0x7a / 255, blue: 0xf0 / 255)
            : Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    }

    private func usageWindow(_ title: String, window: UsageSnapshot.Window, duration: TimeInterval) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(window.remaining.rounded()))% left").monospacedDigit()
            }.font(.caption)
            ProgressView(value: window.remaining, total: 100)
                .tint(barColor)
                .accessibilityLabel("\(title) remaining")
            if let pace = window.paceRemaining(duration: duration, now: context.date) {
                let reserve = Int((window.remaining - pace).rounded())
                Text(reserve >= 0 ? "\(reserve)% in reserve" : "\(-reserve)% over pace")
                    .font(.caption2).foregroundStyle(reserve < 0 ? .orange : .secondary)
            }
            if let reset = window.resetsAt, let date = backendTimestamp(reset) {
                Text("Resets \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        }
    }

}
