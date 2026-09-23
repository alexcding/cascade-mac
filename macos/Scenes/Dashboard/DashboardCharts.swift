import SwiftUI

/// The Dashboard's own colours: the text steps, the stage ramp and the status pills the app palette
/// does not carry. Bars and usage take the menu bar tray's colours, so the two read alike.
enum DashboardPalette {
    static let ink2 = ThemeColor(light: 0x52514E, dark: 0xC3C2B7).color
    static let ink3 = ThemeColor(light: 0x6E6D68, dark: 0x9B9A90).color
    static let hairline = ThemeColor(light: 0xE6E5E0, dark: 0x2C2C2A).color
    static let link = ThemeColor(light: 0x1C5CAB, dark: 0x86B6EF).color
    static let critical = ThemeColor(light: 0xD03B3B, dark: 0xD03B3B).color
    static let criticalText = ThemeColor(light: 0xB02A2A, dark: 0xF08A8A).color
    static let buttonBorder = ThemeColor(light: 0xDDDCD6, dark: 0x383835).color

    /// Ordered stages read light to dark on one hue; Blocked leaves the ramp for the critical hue
    /// and always carries its icon, so it never depends on colour alone.
    static func stage(_ stage: TicketStage) -> Color {
        switch stage {
        case .toDo: return ThemeColor(light: 0x6A9FE4, dark: 0x3F74BF).color
        case .inProgress: return ThemeColor(light: 0x3987E5, dark: 0x2A78D6).color
        case .pendingRelease: return ThemeColor(light: 0x1C5CAB, dark: 0x6DA7EC).color
        case .blocked: return critical
        }
    }

    /// Priority runs warm to cool: red, orange, amber, then a calm blue for Low, so urgency reads
    /// at a glance; the level's arrow glyph carries it without the colour.
    static func priority(_ level: TicketPriority) -> Color {
        switch level {
        case .urgent: return ThemeColor(light: 0xE5484D, dark: 0xEC5D5E).color
        case .high: return ThemeColor(light: 0xF5803A, dark: 0xF28A48).color
        case .medium: return ThemeColor(light: 0xC98A0A, dark: 0xE0AE35).color
        case .low: return ThemeColor(light: 0x7FB0EE, dark: 0x5A92DE).color
        }
    }

    /// A status pill's text and fill; the text clears 4.5:1 on its own fill in both appearances.
    static func pill(_ stage: TicketStage) -> (text: Color, fill: Color) {
        switch stage {
        case .toDo: return (ThemeColor(light: 0x1C4F8F, dark: 0x9EC5F4).color, ThemeColor(light: 0xE6F0FC, dark: 0x1B2B42).color)
        case .inProgress: return (ThemeColor(light: 0x6A4200, dark: 0xF5C45C).color, ThemeColor(light: 0xFCF0D6, dark: 0x382C14).color)
        case .pendingRelease: return (ThemeColor(light: 0x135E3C, dark: 0x6FD49C).color, ThemeColor(light: 0xDEF3E8, dark: 0x15302A).color)
        case .blocked: return (ThemeColor(light: 0xA12626, dark: 0xF08A8A).color, ThemeColor(light: 0xFBE5E5, dark: 0x3A1C1C).color)
        }
    }
}

/// A section's title line: the name, a quiet count or summary, and its refresh button far right,
/// level with the rows' trailing edge; the page's own trailing inset keeps both clear of the scroller.
struct DashboardSectionHeader: View {
    let title: String
    let detail: String
    var refresh: (() -> Void)? = nil
    var busy = false
    /// The refresh button's accessibility id, `dashboard-refresh-<id>`; stable across copy changes.
    var id = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.3)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            if let refresh {
                DashboardRefreshButton(name: title, id: id, busy: busy, action: refresh)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.bottom, 14)
    }
}

/// The outlined refresh button a section carries far right, level with its rows' trailing edge.
struct DashboardRefreshButton: View {
    let name: String
    let id: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                .opacity(busy ? 0 : 1)
                .overlay { if busy { ProgressView().controlSize(.small).scaleEffect(0.6) } }
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(DashboardPalette.buttonBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardPalette.ink2)
        .disabled(busy)
        .accessibilityLabel("Refresh \(name)")
        .accessibilityIdentifier("dashboard-refresh-\(id)")
        .help("Refresh \(name)")
    }
}

// MARK: - AI usage

/// The agents the user has a plan with, each with its quota windows and usage, for the Dashboard's
/// usage rows. An agent with no plan is left out.
@MainActor enum DashboardUsage {
    struct Plan: Identifiable {
        let key: String, title: String
        let limits: UsageSnapshot.Limits
        let agent: UsageSnapshot.Agent?
        var id: String { key }
        /// Session leads for every agent, so the rows read alike; failing that, the first window.
        var lead: (title: String, window: UsageSnapshot.Window, duration: TimeInterval)? {
            if let session = limits.session { return ("Session", session, UsageWindowMath.session) }
            if let weekly = limits.weekly { return ("Weekly", weekly, UsageWindowMath.week) }
            return limits.scoped?.first.map { ($0.label ?? "Model", $0, UsageWindowMath.week) }
        }
    }

    static func plans(_ usage: UsageSnapshot?) -> [Plan] {
        Theme.usageAgents.compactMap { agent in
            let codex = agent.key == "codex"
            guard let limits = codex ? usage?.codexLimits : usage?.limits,
                  limits.session != nil || limits.weekly != nil || !(limits.scoped ?? []).isEmpty else { return nil }
            return Plan(key: agent.key, title: agent.title, limits: limits, agent: codex ? usage?.codex : usage?.claude)
        }
    }

    /// The backend answers its first request at once with an empty snapshot (no `asOf`) while it
    /// gathers the figures, so that still counts as loading.
    static func loading(_ shell: ShellStore) -> Bool {
        plans(shell.usage).isEmpty && shell.usage?.asOf == nil && shell.usageError == nil
    }
}

/// Each agent's quota as ruled rows: a ring of the lead window's use, then when it resets and the
/// weekly figure. A row opens the tray's usage panel for that agent in a popover.
struct DashboardUsageRows: View {
    let shell: ShellStore

    var body: some View {
        let plans = DashboardUsage.plans(shell.usage)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DashboardPalette.hairline).frame(height: 1).accessibilityHidden(true)
            if DashboardUsage.loading(shell) {
                Text("Loading usage…").font(.system(size: 13)).foregroundStyle(DashboardPalette.ink3)
                    .padding(.horizontal, 8).frame(height: 44)
                    .accessibilityIdentifier("dashboard-usage-loading")
            } else {
                ForEach(plans) { AgentUsageRow(plan: $0) }
            }
        }
    }
}

private struct AgentUsageRow: View {
    let plan: DashboardUsage.Plan
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let accent = Theme.agentTint(plan.key)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let lead = plan.lead
            let used = 100 - (lead?.window.remaining ?? 100)
            Button { showing.toggle() } label: {
                HStack(spacing: 14) {
                    UsageRing(used: used, accent: accent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            AgentMark(key: plan.key, size: 13)
                            Text(plan.title).font(.system(size: 13.5, weight: .semibold))
                        }
                        Text(line(lead?.title ?? "Usage", lead?.window, now: context.date))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                        if lead?.title == "Session", let weekly = plan.limits.weekly {
                            Text(line("Weekly", weekly, now: context.date))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(DashboardPalette.ink3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 12)
                .background(hovering || showing ? Color.primary.opacity(0.04) : .clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DashboardPalette.hairline).frame(height: 1).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(plan.title) \(lead?.title ?? "usage")")
            .accessibilityValue("\(Int(used.rounded())) percent used")
            .accessibilityHint("Shows every quota window and the month's cost")
            .accessibilityIdentifier("dashboard-usage-\(plan.key)")
        }
        .popover(isPresented: $showing, arrowEdge: .leading) {
            AgentUsageDetails(plan: plan).padding(16).frame(width: 320)
        }
    }

    /// "Session 62% · resets in 2h 07m"; the reset is left off once it has passed.
    private func line(_ title: String, _ window: UsageSnapshot.Window?, now: Date) -> String {
        guard let window else { return title }
        let used = "\(title) \(Int((100 - window.remaining).rounded()))%"
        return UsageWindowMath.until(window.resetsAt, now: now).map { "\(used) · resets in \($0)" } ?? used
    }
}

/// A quota as a ring: the used share in the agent's colour over a faint track, the figure inside.
private struct UsageRing: View {
    let used: Double
    let accent: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: 6)
            Circle().trim(from: 0, to: max(0, min(1, used / 100)))
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(used.rounded()))%").font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

/// The menu bar tray's usage panel for one agent: a bar per quota window, then the day and month
/// figures and the daily cost chart.
private struct AgentUsageDetails: View {
    let plan: DashboardUsage.Plan
    var body: some View {
        let accent = Theme.agentTint(plan.key)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AgentMark(key: plan.key, size: 15)
                Text(plan.title).font(.system(size: 13, weight: .semibold))
            }
            if let session = plan.limits.session {
                UsageBar(title: "Session", window: session, duration: UsageWindowMath.session, weekly: nil, accent: accent)
            }
            if let weekly = plan.limits.weekly {
                UsageBar(title: "Weekly", window: weekly, duration: UsageWindowMath.week, weekly: plan.limits.session, accent: accent)
            }
            ForEach(Array((plan.limits.scoped ?? []).enumerated()), id: \.offset) { _, window in
                UsageBar(title: "\(window.label ?? "Model") weekly", window: window, duration: UsageWindowMath.week, weekly: nil, accent: accent)
            }
            if let agent = plan.agent { UsageStats(agent: agent, accent: accent) }
        }
    }
}

/// An agent's own mark from the asset catalogue, tinted its colour.
struct AgentMark: View {
    let key: String
    var size: CGFloat = 14
    var body: some View {
        if let asset = PageSessionMark(cli: key).asset {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size).foregroundStyle(Theme.agentTint(key)).accessibilityHidden(true)
        }
    }
}

// MARK: - Tickets

/// The tickets split by workflow stage as one bar, 2pt gaps between segments, with a legend that
/// names and counts each stage. A legend entry opens My Tickets on that stage.
struct TicketStageBar: View {
    let stages: DashboardTicketsModel.StageSummary
    var select: ((TicketStage) -> Void)? = nil

    var body: some View {
        let total = max(1, stages.total)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, stages.live.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(stages.live) { entry in
                        Rectangle().fill(DashboardPalette.stage(entry.stage))
                            .frame(width: max(2, (geometry.size.width - gaps) * CGFloat(entry.count) / CGFloat(total)))
                            .help("\(entry.stage.title): \(entry.count)")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            FlowRow(spacing: 18, lineSpacing: 8) {
                ForEach(stages.all) { entry in
                    Button { select?(entry.stage) } label: {
                        HStack(spacing: 6) {
                            if entry.stage == .blocked {
                                Image(systemName: "nosign").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DashboardPalette.critical)
                            } else {
                                RoundedRectangle(cornerRadius: 2).fill(DashboardPalette.stage(entry.stage)).frame(width: 10, height: 10)
                            }
                            Text(entry.stage.title).foregroundStyle(DashboardPalette.ink2)
                            Text("\(entry.count)").fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(select == nil)
                    .accessibilityLabel("\(entry.stage.title): \(entry.count)")
                    .accessibilityIdentifier("dashboard-stage-\(entry.stage.rawValue)")
                }
            }
        }
    }
}

/// A ticket's priority as Jira draws it: an arrow shape per level in the level's colour, named in
/// the tooltip and to VoiceOver.
struct TicketPriorityMark: View {
    let level: TicketPriority
    var body: some View {
        Image(systemName: level.symbol).font(.system(size: 10, weight: .bold))
            .foregroundStyle(DashboardPalette.priority(level)).frame(width: 14)
            .help("\(level.title) priority").accessibilityLabel("\(level.title) priority")
    }
}

/// A ticket's status as a filled pill, coloured by its stage.
struct TicketStatusPill: View {
    let row: DashboardTicketRow
    var body: some View {
        if !row.status.isEmpty {
            let colors = DashboardPalette.pill(row.stage)
            Text(row.status).font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.text)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 7).frame(height: 20)
                .background(colors.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
