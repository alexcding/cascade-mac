import SwiftUI

/// The Live tab: the session's agent drawn as a running diagram. The agent on the left, wired to a
/// box for each kind of tool; a call sends a packet down its wire, a running one keeps its wire
/// lit, and the latest calls scroll by in a log underneath.
struct LivePanelView: View {
    let live: LivePanelModel
    let workspace: SessionWorkspaceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LiveAgentHeader(workspace: workspace, model: live.activity.model)
                LiveDiagram(live: live, busy: workspace.agentRunState == .working, tint: workspace.agentDriver?.tint ?? Theme.accent)
                    .frame(height: LiveDiagram.height)
                if !live.activity.subagents.isEmpty { LiveSubagents(calls: live.activity.subagents) }
                LiveCounters(activity: live.activity)
                LiveLog(calls: live.activity.log)
                if let error = live.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
        .paneSurface(ignoresSafeAreaEdges: [])
        .onAppear { live.appear() }
        .onDisappear { live.disappear() }
        .accessibilityIdentifier("workspace-live-panel")
    }
}

/// The agent's name and state, the model it runs and how full its context is.
private struct LiveAgentHeader: View {
    let workspace: SessionWorkspaceViewModel
    let model: String?

    private var state: (String, Color) {
        switch workspace.agentRunState {
        case .notRunning: (String(localized: "Not running"), Theme.textTertiary)
        case .waiting: (String(localized: "Waiting on you"), Theme.warn)
        case .working: (String(localized: "Working"), Theme.success)
        case .idle: (String(localized: "Idle"), Theme.textTertiary)
        }
    }

    var body: some View {
        let (label, color) = state
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(workspace.agentDriver?.name ?? String(localized: "Agent")).font(.headline)
                Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            if let name = workspace.agentStatus?.model ?? model {
                Text(name).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            if let fraction = workspace.agentStatus?.fraction {
                ProgressView(value: fraction) { EmptyView() } currentValueLabel: {
                    Text(String(localized: "Context \(Int((fraction * 100).rounded()))%")).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                .tint(fraction > 0.8 ? Theme.warn : Theme.accent)
            }
        }
    }
}

/// The agent box wired to one box a lane. Wires and packets are drawn in a canvas under the boxes,
/// redrawn every frame only while something moves.
private struct LiveDiagram: View {
    let live: LivePanelModel
    let busy: Bool
    let tint: Color

    static let lanes = LiveActivity.Lane.allCases
    static let rowHeight: CGFloat = 34
    static let rowGap: CGFloat = 8
    static var height: CGFloat { CGFloat(lanes.count) * rowHeight + CGFloat(lanes.count - 1) * rowGap }

    /// A lit wire sends a packet down it this often.
    private static let loop: TimeInterval = 1.2

    var body: some View {
        let activity = live.activity
        let moving = live.isVisible && (!live.pulses.isEmpty || !activity.running.isEmpty)
        GeometryReader { proxy in
            let layout = Layout(size: proxy.size)
            // A packet loops every 1.2s: 30 frames a second is smooth, and a long call costs less.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
                Canvas { context, _ in
                    draw(into: &context, layout: layout, at: timeline.date)
                }
            }
            LiveBox(title: busy ? String(localized: "Working") : String(localized: "Agent"), symbol: "sparkle",
                    detail: String(localized: "\(activity.calls) calls"), lit: busy, tint: tint)
                .frame(width: layout.agent.width, height: layout.agent.height)
                .position(x: layout.agent.midX, y: layout.agent.midY)
            ForEach(Self.lanes, id: \.self) { lane in
                let rect = layout.lane(lane)
                LiveBox(title: lane.title, symbol: lane.symbol, detail: "\(activity.counts[lane] ?? 0)",
                        lit: activity.running.contains(lane), tint: tint)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func draw(into context: inout GraphicsContext, layout: Layout, at date: Date) {
        let activity = live.activity
        for lane in Self.lanes {
            let points = layout.wire(lane)
            var path = Path()
            path.addLines(points)
            let lit = activity.running.contains(lane)
            context.stroke(path, with: .color(lit ? tint.opacity(0.7) : Theme.border), style: .init(lineWidth: lit ? 1.5 : 1, lineJoin: .round))
            // A running call keeps packets going down its wire, a few apart.
            if lit {
                let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.loop) / Self.loop
                for offset in [0.0, 1.0 / 3, 2.0 / 3] {
                    packet(&context, at: Self.point(along: points, fraction: (phase + offset).truncatingRemainder(dividingBy: 1)), size: 4, opacity: 0.6)
                }
            }
        }
        for pulse in live.pulses {
            let progress = date.timeIntervalSince(pulse.start) / LivePulse.duration
            guard (0...1).contains(progress) else { continue }
            packet(&context, at: Self.point(along: layout.wire(pulse.lane), fraction: progress), size: 7, opacity: 1)
        }
    }

    private func packet(_ context: inout GraphicsContext, at point: CGPoint, size: CGFloat, opacity: Double) {
        let glow = CGRect(x: point.x - size, y: point.y - size, width: size * 2, height: size * 2)
        context.fill(Path(ellipseIn: glow), with: .color(tint.opacity(0.25 * opacity)))
        let dot = glow.insetBy(dx: size / 2, dy: size / 2)
        context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(opacity)))
    }

    /// The point a fraction of the way along a polyline, by length.
    static func point(along points: [CGPoint], fraction: Double) -> CGPoint {
        let segments = zip(points, points.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
        var remaining = segments.reduce(0) { $0 + $1.2 } * min(1, max(0, fraction))
        for (from, to, length) in segments {
            if remaining <= length, length > 0 {
                let t = remaining / length
                return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            }
            remaining -= length
        }
        return points.last ?? .zero
    }

    /// The agent's box at the left, middle high; the lanes stacked down the right; between them
    /// the bus each wire turns down.
    struct Layout {
        let size: CGSize
        var agent: CGRect {
            let width = min(140, size.width * 0.38)
            return CGRect(x: 0, y: (size.height - 56) / 2, width: width, height: 56)
        }
        private var laneX: CGFloat { agent.maxX + max(36, size.width * 0.14) }
        func lane(_ lane: LiveActivity.Lane) -> CGRect {
            let index = CGFloat(LiveActivity.Lane.allCases.firstIndex(of: lane) ?? 0)
            return CGRect(x: laneX, y: index * (LiveDiagram.rowHeight + LiveDiagram.rowGap),
                          width: size.width - laneX, height: LiveDiagram.rowHeight)
        }
        func wire(_ lane: LiveActivity.Lane) -> [CGPoint] {
            let to = self.lane(lane)
            let bus = (agent.maxX + laneX) / 2
            return [CGPoint(x: agent.maxX, y: agent.midY), CGPoint(x: bus, y: agent.midY),
                    CGPoint(x: bus, y: to.midY), CGPoint(x: to.minX, y: to.midY)]
        }
    }
}

/// A box of the diagram: its symbol, name and count, lit while it works.
private struct LiveBox: View {
    let title: String
    let symbol: String
    let detail: String
    let lit: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(lit ? tint : Theme.textSecondary).frame(width: 16)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(lit ? tint.opacity(0.12) : Theme.surfaceHover))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(lit ? tint.opacity(0.8) : Theme.border, lineWidth: 1))
        .shadow(color: lit ? tint.opacity(0.35) : .clear, radius: 6)
        .animation(.easeOut(duration: 0.25), value: lit)
    }
}

/// The subagents the turn under way started: running, done or failed.
private struct LiveSubagents: View {
    let calls: [LiveActivity.Call]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Subagents")).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(calls) { call in
                HStack(spacing: 8) {
                    LiveCallState(call: call)
                    Text(call.label).font(.caption).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// The tallies of the transcript as the backend reads it: its latest turns, not the whole session.
private struct LiveCounters: View {
    let activity: LiveActivity
    var body: some View {
        HStack(spacing: 0) {
            counter(String(localized: "Calls"), activity.calls)
            counter(String(localized: "Edits"), activity.counts[.edit] ?? 0)
            counter(String(localized: "Failed"), activity.failures, color: activity.failures > 0 ? Theme.danger : nil)
            counter(String(localized: "Prompts"), activity.prompts)
        }
    }
    private func counter(_ title: String, _ value: Int, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(color ?? .primary)
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
            Text(title).font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .help(String(localized: "Counted over the conversation's recent turns"))
    }
}

/// The latest calls, newest at the bottom and brightest, the older ones fading up the list.
private struct LiveLog: View {
    let calls: [LiveActivity.Call]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Latest")).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            if calls.isEmpty {
                Text(String(localized: "No tool calls yet.")).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                HStack(spacing: 8) {
                    LiveCallState(call: call)
                    Image(systemName: call.lane?.symbol ?? "wrench.and.screwdriver").font(.system(size: 10)).foregroundStyle(Theme.textTertiary).frame(width: 14)
                    Text(call.label).font(.system(size: 11).monospaced()).lineLimit(1).truncationMode(.middle)
                }
                .opacity(1 - Double(calls.count - 1 - index) * 0.13)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: calls.map(\.id))
    }
}

/// A spinner while a call runs, a cross for one that failed, else a tick.
private struct LiveCallState: View {
    let call: LiveActivity.Call
    var body: some View {
        Group {
            if call.running { ProgressView().controlSize(.mini) }
            else if call.failed { Image(systemName: "xmark").foregroundStyle(Theme.danger) }
            else { Image(systemName: "checkmark").foregroundStyle(Theme.success) }
        }
        .font(.system(size: 9, weight: .bold))
        .frame(width: 12, height: 12)
    }
}
