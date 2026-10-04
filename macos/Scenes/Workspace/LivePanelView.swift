import SwiftUI

/// The Live tab: the session's agent drawn as a running diagram, top down. The agent leads; its
/// calls run down a wire to the tools, each kind a bar; the subagents it started sit side by side
/// under them, and the files it last changed under those; the session log runs along the bottom.
/// Dashed monospaced boxes, as a terminal draws them, in the theme's colours. A call starting sends
/// a packet down the wires; a running one keeps its bar lit.
struct LivePanelView: View {
    let live: LivePanelModel
    let workspace: SessionWorkspaceViewModel

    var body: some View {
        let activity = live.activity
        let tint = workspace.agentDriver?.tint ?? Theme.accent
        // Moving while something does: a packet on its way, a call running, a spinner turning.
        let moving = live.isVisible && (!live.pulses.isEmpty || !activity.running.isEmpty)
        // No scroll view: SwiftUI stretches one up under the title bar, over the pane's tabs, where
        // it takes their clicks. The panel is fixed; a pane shorter than it cuts the log.
        // Smooth while a packet moves; a spinner turning needs no more than its own eight frames.
        TimelineView(.animation(minimumInterval: live.pulses.isEmpty ? 1.0 / 8 : 1.0 / 30, paused: !moving)) { timeline in
            let now = timeline.date
            VStack(spacing: 0) {
                LiveAgentBox(workspace: workspace, model: activity.model, calls: activity.calls, tint: tint)
                LiveWire(packets: live.pulses.map { progress(of: $0, at: now) }, tint: tint)
                LiveToolsBox(activity: activity, tint: Theme.success, now: now)
                if !activity.subagents.isEmpty {
                    LiveWire(packets: live.pulses.filter { $0.lane == .delegate }.map { progress(of: $0, at: now) }, tint: Theme.accent)
                    LiveSubagentsRow(calls: activity.subagents, now: now)
                }
                if !activity.files.isEmpty {
                    LiveWire(packets: [], tint: Theme.success)
                    LiveFilesBox(files: activity.files, now: now)
                }
                LiveLog(calls: activity.log, now: now)
                    .padding(.top, 16)
                if let error = live.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn)
                        .padding(.top, 8)
                }
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
        .paneSurface(ignoresSafeAreaEdges: [])
        .onAppear { live.appear() }
        .onDisappear { live.disappear() }
        .accessibilityIdentifier("workspace-live-panel")
    }

    private func progress(of pulse: LivePulse, at now: Date) -> Double {
        now.timeIntervalSince(pulse.start) / LivePulse.duration
    }
}

// MARK: Boxes

/// The agent at the head: its name, model and state, how hard it thinks, and how full its context is.
private struct LiveAgentBox: View {
    let workspace: SessionWorkspaceViewModel
    let model: String?
    let calls: Int
    let tint: Color

    private var state: (String, Color) {
        switch workspace.agentRunState {
        case .notRunning: (String(localized: "not running"), Theme.textTertiary)
        case .waiting: (String(localized: "waiting on you"), Theme.warn)
        case .working: (String(localized: "working"), Theme.success)
        case .idle: (String(localized: "idle"), Theme.textTertiary)
        }
    }

    var body: some View {
        let (label, color) = state
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(verbatim: "\(workspace.agentDriver?.name ?? String(localized: "Agent")) · \(label)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(tint)
            }
            if let name = workspace.agentStatus?.model ?? model {
                Text(name).foregroundStyle(.primary).lineLimit(1)
            }
            HStack(spacing: 14) {
                if let effort = workspace.agentEffort { LiveEffort(name: effort.name, fraction: effort.fraction, tint: tint) }
                if let fraction = workspace.agentStatus?.fraction {
                    Text(String(localized: "context \(Int((fraction * 100).rounded()))%"))
                        .foregroundStyle(fraction > 0.8 ? Theme.warn : Theme.textSecondary)
                }
            }
            HStack(spacing: 6) {
                Text(String(localized: "calls")).foregroundStyle(Theme.textTertiary)
                Text(verbatim: "\(calls)").monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12).padding(.horizontal, 10)
        .liveFrame(tint)
    }
}

/// The effort the agent runs at, as four blocks lit to how far up its model's efforts it is. One
/// with no place among them (`auto`) is named alone.
private struct LiveEffort: View {
    let name: String
    let fraction: Double
    let tint: Color
    var body: some View {
        let level = Int((fraction * 4).rounded(.up))
        HStack(spacing: 6) {
            Text(String(localized: "effort")).foregroundStyle(Theme.textSecondary)
            if fraction > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Rectangle().fill(index < level ? tint : Theme.border).frame(width: 7, height: 12)
                    }
                }
            }
            Text(verbatim: name).foregroundStyle(tint)
        }
    }
}

/// The tools, one row a kind: its bar as long as its share of the calls, lit while one runs.
private struct LiveToolsBox: View {
    let activity: LiveActivity
    let tint: Color
    let now: Date

    var body: some View {
        let most = max(1, activity.counts.values.max() ?? 0)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(String(localized: "tools")).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                Spacer()
                Text(String(localized: "calls")).foregroundStyle(Theme.textTertiary)
                Text(verbatim: "\(activity.calls)").fontWeight(.bold).monospacedDigit()
            }
            ForEach(LiveActivity.Lane.allCases, id: \.self) { lane in
                let count = activity.counts[lane] ?? 0, running = activity.running.contains(lane)
                HStack(spacing: 8) {
                    Text(lane.title.lowercased()).frame(width: 52, alignment: .leading).lineLimit(1)
                    LiveBar(fraction: Double(count) / Double(most), lit: running, tint: running ? tint : Theme.textTertiary, now: now)
                    Text(verbatim: "\(count)").monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text(running ? LiveSpinner.frame(at: now) : " ").foregroundStyle(tint).frame(width: 10)
                }
                .foregroundStyle(running ? Color.primary : Theme.textSecondary)
            }
            if activity.failures > 0 {
                HStack(spacing: 6) {
                    Text(String(localized: "failed"))
                    Text(verbatim: "\(activity.failures)").monospacedDigit()
                }
                .foregroundStyle(Theme.danger)
            }
        }
        .padding(12)
        .liveFrame(tint)
    }
}

/// A bar of a row: filled to its share over a faint track; a lit one shimmers.
private struct LiveBar: View {
    let fraction: Double
    let lit: Bool
    let tint: Color
    let now: Date

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border.opacity(0.5))
                Rectangle().fill(tint.opacity(lit ? 0.55 + 0.35 * shimmer : 0.45)).frame(width: max(fraction > 0 ? 2 : 0, width))
            }
        }
        .frame(height: 10)
    }
    private var shimmer: Double { (sin(now.timeIntervalSinceReferenceDate * 6) + 1) / 2 }
}

/// The subagents of the turn under way, side by side as they fit.
private struct LiveSubagentsRow: View {
    let calls: [LiveActivity.Call]
    let now: Date

    var body: some View {
        // Up to three abreast, sharing the width; more wrap under them.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(3, calls.count)), spacing: 8) {
            ForEach(calls) { call in
                VStack(spacing: 6) {
                    Text(String(localized: "subagent")).font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text(call.label).foregroundStyle(Theme.textSecondary).lineLimit(2).multilineTextAlignment(.center)
                    LiveStatus(call: call, now: now)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .liveFrame(Theme.accent)
            }
        }
    }
}

/// The files the agent last changed, side by side, with what it did to each.
private struct LiveFilesBox: View {
    let files: [LiveActivity.Call]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "files · last changed")).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.success)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().padding(.horizontal, 6) }
                    VStack(spacing: 3) {
                        Text(((file.path ?? file.label) as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: file.running ? "[\(LiveSpinner.frame(at: now)) \(verb(file))]" : "[\(verb(file))]")
                            .foregroundStyle(file.failed ? Theme.danger : Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(file.path ?? file.label)
                }
            }
            // As tall as the names, not as tall as the dividers would grow.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .liveFrame(Theme.success)
    }
    private func verb(_ file: LiveActivity.Call) -> String {
        file.kind == "create" ? String(localized: "+ new") : String(localized: "✎ edit")
    }
}

/// The latest calls as a trace: when, which kind, what, and how it ended; the newest marked.
private struct LiveLog: View {
    let calls: [LiveActivity.Call]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.border).frame(width: 10, height: 1)
                Text(String(localized: "session log")).foregroundStyle(Theme.textSecondary)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if calls.isEmpty {
                Text(String(localized: "no tool calls yet")).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                let newest = index == calls.count - 1
                HStack(spacing: 8) {
                    Text(newest ? "›" : " ").foregroundStyle(Theme.accent).frame(width: 8)
                    // In the person's own clock, 12- or 24-hour.
                    Text(verbatim: call.time?.formatted(date: .omitted, time: .standard) ?? "--:--:--").foregroundStyle(Theme.textTertiary)
                    Text(call.lane?.title.lowercased() ?? call.kind ?? String(localized: "tool")).foregroundStyle(Theme.success).frame(width: 48, alignment: .leading)
                    Text(call.label).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    LiveStatus(call: call, now: now)
                }
                .fontWeight(newest ? .semibold : .regular)
                .opacity(newest ? 1 : 0.75)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: calls.map(\.id))
    }
}

/// `[\ running]` while a call runs, then how it ended.
private struct LiveStatus: View {
    let call: LiveActivity.Call
    let now: Date
    var body: some View {
        if call.running { Text(verbatim: "[\(LiveSpinner.frame(at: now)) \(String(localized: "running"))]").foregroundStyle(Theme.accent) }
        else if call.failed { Text(verbatim: "[\(String(localized: "failed"))]").foregroundStyle(Theme.danger) }
        else { Text(verbatim: "[\(String(localized: "ok"))]").foregroundStyle(Theme.success) }
    }
}

/// A terminal's spinner: the frame for a moment in time.
private enum LiveSpinner {
    static func frame(at date: Date) -> String {
        ["|", "/", "-", "\\"][Int(date.timeIntervalSinceReferenceDate * 8) % 4]
    }
}

// MARK: Wires and frames

/// The wire from one box down to the next: a dashed line ending in an arrowhead, packets running
/// down it.
private struct LiveWire: View {
    /// How far along each packet is, 0 at the top to 1 at the arrow.
    let packets: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let x = size.width / 2
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height - 6))
            context.stroke(line, with: .color(tint.opacity(0.6)), style: .init(lineWidth: 1, dash: [3, 3]))
            var head = Path()
            head.move(to: CGPoint(x: x - 5, y: size.height - 7)); head.addLine(to: CGPoint(x: x + 5, y: size.height - 7))
            head.addLine(to: CGPoint(x: x, y: size.height - 1)); head.closeSubpath()
            context.fill(head, with: .color(tint))
            for progress in packets where (0...1).contains(progress) {
                let y = (size.height - 8) * progress
                let glow = CGRect(x: x - 6, y: y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: glow), with: .color(tint.opacity(0.3)))
                context.fill(Path(ellipseIn: glow.insetBy(dx: 3, dy: 3)), with: .color(tint))
            }
        }
        .frame(height: 24)
    }
}

/// A dashed frame with a tick at each corner, as a terminal diagram draws a box.
private struct LiveFrame: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
                context.stroke(Path(rect), with: .color(tint.opacity(0.7)), style: .init(lineWidth: 1, dash: [4, 3]))
                for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: corner.x - 3, y: corner.y)); tick.addLine(to: CGPoint(x: corner.x + 3, y: corner.y))
                    tick.move(to: CGPoint(x: corner.x, y: corner.y - 3)); tick.addLine(to: CGPoint(x: corner.x, y: corner.y + 3))
                    context.stroke(tick, with: .color(tint), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private extension View {
    func liveFrame(_ tint: Color) -> some View { modifier(LiveFrame(tint: tint)) }
}
