import SwiftUI

/// The plan-usage block: one bar per allowance window (Session, Weekly, each scoped model).
/// Each bar is drawn the way the Task Hub tray drew it — a grey track, the agent's accent
/// fill, faint gridmarks, and a green pace notch where the fill would sit on an even spend.
struct UsagePanel: View {
    let shell: ShellStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if shell.usageLoading && shell.usage == nil {
                ProgressView("Loading usage…").controlSize(.small)
            }
            if let error = shell.usageError { Text(error).font(.caption).foregroundStyle(.orange) }
            let snapshot = shell.usage
            let agent = shell.usageAgent == "codex" ? snapshot?.codex : snapshot?.claude
            let limits = shell.usageAgent == "codex" ? snapshot?.codexLimits : snapshot?.limits
            if let session = limits?.session {
                UsageBar(title: "Session", window: session, duration: UsageWindowMath.session, weekly: nil, accent: accent)
            }
            if let weekly = limits?.weekly {
                UsageBar(title: "Weekly", window: weekly, duration: UsageWindowMath.week, weekly: limits?.session, accent: accent)
            }
            if let scoped = limits?.scoped {
                ForEach(Array(scoped.enumerated()), id: \.offset) { _, window in
                    UsageBar(title: "\(window.label ?? "Model") weekly", window: window, duration: UsageWindowMath.week, weekly: nil, accent: accent)
                }
            }
            if let agent { UsageStats(agent: agent, accent: accent) }
            if agent == nil && limits == nil && !shell.usageLoading {
                Text("Usage is unavailable").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Each agent's own accent, the Dashboard's.
    private var accent: Color { Theme.agentTint(shell.usageAgent) }
}

enum UsageWindowMath {
    static let session: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400

    /// "2h 07m", "4d 1h", "12m"; nil once the reset has passed.
    static func until(_ resetsAt: String?, now: Date) -> String? {
        guard let resetsAt, let reset = backendTimestamp(resetsAt) else { return nil }
        let minutes = Int(reset.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return nil }
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageSnapshot.Window
    let duration: TimeInterval
    /// For the weekly bar: the session window, so the caption can say how many more sessions
    /// like the current one fit in what is left.
    let weekly: UsageSnapshot.Window?
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let left = window.remaining
            let pace = window.paceRemaining(duration: duration, now: now)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(title) \(Int(left.rounded()))% left").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Spacer(minLength: 8)
                    if let until = UsageWindowMath.until(window.resetsAt, now: now) {
                        Text("Resets in \(until)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                track(left: left, pace: pace)
                Text(caption(left: left, pace: pace, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Track, fill, gridmarks at the quarters, then the green pace notch on top.
    private func track(left: Double, pace: Double?) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(accent).frame(width: (width * left / 100).rounded())
                // Gridmarks and the notch's halo are cut out of the bar, not painted over it, so
                // the menu's own material shows through whatever theme it is drawn on.
                ForEach([25.0, 50.0, 75.0], id: \.self) { mark in
                    Rectangle().fill(.black).frame(width: 2).offset(x: (width * mark / 100).rounded() - 1).blendMode(.destinationOut)
                }
                if let pace {
                    let x = (width * pace / 100).rounded()
                    Rectangle().fill(.black).frame(width: 7).offset(x: x - 3.5).blendMode(.destinationOut)
                    Rectangle().fill(Color(nsColor: SidebarPalette.success)).frame(width: 3).offset(x: x - 1.5)
                        .accessibilityLabel("Pace")
                }
            }
            .compositingGroup()
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }

    /// "36% in reserve · Lasts until reset", or "12% over pace · Runs out before reset". The
    /// weekly bar adds how many session windows remain before its reset. (The API measures the
    /// session and weekly windows against different caps, so "sessions left" is not computable.)
    private func caption(left: Double, pace: Double?, now: Date) -> String {
        var parts: [String] = []
        if let pace {
            let reserve = Int((left - pace).rounded())
            parts.append(reserve >= 0 ? "\(reserve)% in reserve" : "\(-reserve)% over pace")
            parts.append(reserve >= 0 ? "Lasts until reset" : "Runs out before reset")
        }
        if weekly != nil {
            if let resetsAt = window.resetsAt, let reset = backendTimestamp(resetsAt), reset > now {
                parts.append("\(Int((reset.timeIntervalSince(now) / UsageWindowMath.session).rounded(.up))) windows until reset")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Under the bars: today's and the month's cost and tokens, the month as a bar chart of daily
/// cost with its ceiling labelled, and the model that cost the most.
private struct UsageStats: View {
    let agent: UsageSnapshot.Agent
    let accent: Color

    var body: some View {
        let history = agent.history ?? []
        let monthCost = history.reduce(0) { $0 + $1.cost }
        let monthTokens = history.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    stat("Today", Self.money(agent.cost))
                    stat("30d cost", Self.money(history.isEmpty ? agent.cost : monthCost))
                }
                GridRow {
                    stat("Latest tokens", Self.compact(agent.tokens))
                    stat("30d tokens", Self.compact(history.isEmpty ? agent.tokens : monthTokens))
                }
            }
            if history.count > 1 { chart(history) }
            if let model = agent.topModel {
                Text("Top model: \(model)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ history: [UsageSnapshot.Day]) -> some View {
        let peak = max(history.map(\.cost).max() ?? 0, 0.01)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(Self.money(peak, whole: true)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(history, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent.opacity(0.85))
                        .frame(height: max(2, 56 * day.cost / peak))
                        .frame(maxWidth: .infinity)
                        .help("\(day.date): \(Self.money(day.cost)) · \(Self.compact(day.tokens)) tokens")
                }
            }
            .frame(height: 56, alignment: .bottom)
        }
        .accessibilityLabel("Daily cost, last \(history.count) days, peak \(Self.money(peak))")
    }

    static func money(_ value: Double, whole: Bool = false) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)))
    }
    /// "20M", "3.2B", "850K": one decimal only when the leading figure is a single digit.
    static func compact(_ value: Double) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            return scaled.formatted(.number.precision(.fractionLength(scaled < 10 ? 1 : 0))) + suffix
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
