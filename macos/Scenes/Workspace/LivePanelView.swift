import SwiftUI

/// The Live tab: the session's agent drawn as an architecture diagram that runs. A heading and a
/// legend; the agent's box; its tools as a table, the kind at work banded; the subagents it started
/// fanned out under them and gathered back into the files it last changed; the session log at the
/// foot. While the agent works one dot runs down each connector. The look is the person's pick of
/// `LiveTheme`, from the row at the top.
struct LivePanelView: View {
    let live: LivePanelModel
    let workspace: SessionWorkspaceViewModel

    var body: some View {
        let palette = live.theme.palette
        let activity = live.activity
        let flowing = live.isVisible && workspace.agentRunState == .working
        // No scroll view: SwiftUI stretches one up under the title bar, over the pane's tabs, where
        // it takes their clicks. The panel is fixed; a pane shorter than it cuts the log.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !flowing)) { timeline in
            let clock = LiveClock(time: timeline.date.timeIntervalSinceReferenceDate, flowing: flowing)
            VStack(spacing: 0) {
                LiveThemeRow(live: live, palette: palette)
                LiveHeading(workspace: workspace, model: activity.model, palette: palette)
                LiveBox(color: palette.agent, palette: palette) {
                    LiveAgentDetails(workspace: workspace, calls: activity.calls, palette: palette)
                }
                LiveConnector(shape: .straight, palette: palette, clock: clock).frame(height: 26)
                LiveBox(color: palette.tools, palette: palette) {
                    LiveToolsTable(activity: activity, palette: palette)
                }
                if !activity.subagents.isEmpty {
                    // Three boxes at most: the running ones first, then the latest; the caption
                    // counts the rest.
                    let shown = Array((activity.subagents.filter(\.running) + activity.subagents.reversed().filter { !$0.running }).prefix(3))
                    let running = activity.subagents.filter(\.running).count, hidden = activity.subagents.count - shown.count
                    Text(hidden > 0 ? String(localized: "subagents · \(running) running · \(hidden) more")
                                    : String(localized: "subagents · \(running) running"))
                        .font(palette.font(12, weight: .bold)).padding(.top, 10)
                    LiveConnector(shape: .fanOut(shown.count), palette: palette, clock: clock).frame(height: 30)
                    HStack(alignment: .top, spacing: LiveConnector.columnGap) {
                        ForEach(shown) { call in
                            LiveBox(color: palette.subagents, palette: palette) {
                                LiveSubagent(call: call, palette: palette, spinner: clock.spinner)
                            }
                        }
                    }
                    if !activity.files.isEmpty {
                        LiveConnector(shape: .fanIn(shown.count), palette: palette, clock: clock).frame(height: 30)
                    }
                } else if !activity.files.isEmpty {
                    LiveConnector(shape: .straight, palette: palette, clock: clock).frame(height: 26)
                }
                if !activity.files.isEmpty {
                    LiveBox(color: palette.agent, palette: palette) { LiveFiles(files: activity.files, palette: palette) }
                }
                // The log takes the height the diagram leaves, as the pane is resized.
                LiveLog(calls: activity.log, palette: palette, spinner: clock.spinner)
                    .frame(minHeight: 80, maxHeight: .infinity)
                    .padding(.top, 18)
                if let error = live.error {
                    Text(error).font(palette.font(11)).foregroundStyle(palette.danger.color).padding(.top, 8)
                }
            }
        }
        .font(palette.font(11.5))
        .foregroundStyle(palette.text.color)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
        .background(palette.ground.color, ignoresSafeAreaEdges: [])
        .onAppear { live.appear() }
        .onDisappear { live.disappear() }
        .accessibilityIdentifier("workspace-live-panel")
    }
}

/// The moment a frame is drawn at, and whether anything moves in it.
private struct LiveClock {
    let time: TimeInterval
    let flowing: Bool
    /// How far along its connector a dot is, 0 to 1, a connector's dots set apart by `offset`.
    func progress(offset: Double = 0) -> Double {
        (time / 1.8 + offset).truncatingRemainder(dividingBy: 1)
    }
    /// A quarter-moon spinner, turning while the agent works.
    var spinner: String { flowing ? ["◐", "◓", "◑", "◒"][Int(time * 4) % 4] : "◐" }
}

// MARK: The bar at the top

/// The look, as a menu at the panel's top right: a palette and the look's name, the looks under
/// it with the one in use ticked.
private struct LiveThemeRow: View {
    let live: LivePanelModel
    let palette: LivePalette

    var body: some View {
        HStack {
            Spacer()
            Menu {
                Picker(String(localized: "Theme"), selection: Binding(get: { live.theme }, set: live.setTheme)) {
                    ForEach(LiveTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paintpalette")
                    Text(live.theme.title)
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.muted.color)
            }
            // A plain button keeps the label in the look's own colours.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .fixedSize()
            .help(String(localized: "Theme"))
            .accessibilityLabel(String(localized: "Theme"))
        }
        .padding(.bottom, 8)
    }
}

/// The diagram's title and legend: the agent, its model and state, then a key to the sections.
private struct LiveHeading: View {
    let workspace: SessionWorkspaceViewModel
    let model: String?
    let palette: LivePalette

    private var state: (String, ThemeColor) {
        switch workspace.agentRunState {
        case .notRunning: (String(localized: "not running"), palette.muted)
        case .waiting: (String(localized: "waiting on you"), palette.log)
        case .working: (String(localized: "working"), palette.tools)
        case .idle: (String(localized: "idle"), palette.muted)
        }
    }

    var body: some View {
        let (label, color) = state
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: (workspace.agentDriver?.name ?? String(localized: "Agent")).uppercased()).fontWeight(.bold)
                Text(verbatim: "·").foregroundStyle(palette.muted.color)
                if let model = workspace.agentStatus?.model ?? model {
                    Text(verbatim: model).foregroundStyle(palette.agent.color).lineLimit(1)
                    Text(verbatim: "·").foregroundStyle(palette.muted.color)
                }
                Text(label.uppercased()).fontWeight(.bold).foregroundStyle(color.color)
            }
            .font(palette.font(12))
            Rectangle().fill(palette.line.color).frame(height: 1)
            HStack(spacing: 12) {
                legend(String(localized: "agent"), palette.agent)
                legend(String(localized: "tools"), palette.tools)
                legend(String(localized: "subagents"), palette.subagents)
                legend(String(localized: "log"), palette.log)
            }
            .font(palette.font(11))
        }
        .padding(.bottom, 12)
    }

    private func legend(_ title: String, _ color: ThemeColor) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color.color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(palette.muted.color)
        }
    }
}

// MARK: Boxes

/// A section's box: outlined in its colour.
private struct LiveBox<Content: View>: View {
    let color: ThemeColor
    let palette: LivePalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
        content()
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(palette.surface.color, in: shape)
            .overlay(shape.strokeBorder(color.color, lineWidth: 1.25))
    }
}

/// The agent: its name and state, then how hard it thinks, how full its context is and how many
/// calls it has made, as the reference's bars.
private struct LiveAgentDetails: View {
    let workspace: SessionWorkspaceViewModel
    let calls: Int
    let palette: LivePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "\(workspace.agentDriver?.name ?? String(localized: "Agent")) · lead"))
                .font(palette.font(13, weight: .bold)).foregroundStyle(palette.agent.color)
                .frame(maxWidth: .infinity)
            if let effort = workspace.agentEffort {
                row(String(localized: "effort"), fraction: effort.fraction, value: effort.name)
            }
            if let fraction = workspace.agentStatus?.fraction {
                row(String(localized: "context"), fraction: fraction, value: "\(Int((fraction * 100).rounded()))%")
            }
            HStack(spacing: 8) {
                Text(String(localized: "calls")).frame(width: 64, alignment: .leading)
                Text(verbatim: "\(calls)").fontWeight(.bold).foregroundStyle(palette.agent.color)
            }
        }
    }

    private func row(_ title: String, fraction: Double, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            LiveBar(fraction: fraction, color: palette.agent, palette: palette)
            Text(verbatim: value).fontWeight(.bold).foregroundStyle(palette.agent.color).frame(width: 64, alignment: .leading).lineLimit(1)
        }
    }
}

/// A bar as the reference draws one: solid to its share, dotted for the rest.
private struct LiveBar: View {
    let fraction: Double
    let color: ThemeColor
    let palette: LivePalette

    var body: some View {
        Canvas { context, size in
            let filled = size.width * min(1, max(0, fraction))
            context.fill(Path(CGRect(x: 0, y: 0, width: filled, height: size.height)), with: .color(color.color))
            var x = filled + 2
            while x < size.width {
                for y in stride(from: 1.5, to: size.height, by: 3) {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(palette.muted.color.opacity(0.7)))
                }
                x += 3
            }
        }
        .frame(height: 12)
    }
}

/// The tools: one row a kind, its count and what it last did; the kind at work banded and marked.
private struct LiveToolsTable: View {
    let activity: LiveActivity
    let palette: LivePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(localized: "tools · \(activity.calls) calls"))
                    .font(palette.font(12, weight: .bold)).foregroundStyle(palette.tools.color)
                Spacer()
                if activity.failures > 0 {
                    Text(String(localized: "failed \(activity.failures)")).foregroundStyle(palette.danger.color)
                }
            }
            .padding(.bottom, 3)
            ForEach(LiveActivity.Lane.allCases, id: \.self) { lane in
                let running = activity.running.contains(lane)
                let latest = activity.latest[lane]
                HStack(spacing: 8) {
                    Text(lane.title.lowercased()).fontWeight(.bold).frame(width: 50, alignment: .leading)
                    Text(verbatim: "\(activity.counts[lane] ?? 0)").foregroundStyle(palette.muted.color).frame(width: 30, alignment: .trailing)
                    Text(verbatim: latest.map { "→ \($0.label)" } ?? "").foregroundStyle(latest?.failed == true ? palette.danger.color : palette.tools.color)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    if running { Text(String(localized: "◂ now")).fontWeight(.bold).foregroundStyle(palette.tools.color) }
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(running ? palette.band.color : .clear)
                .foregroundStyle(latest == nil ? palette.muted.color : palette.text.color)
            }
        }
    }
}

/// A subagent the turn started: what it was asked, and where it is.
private struct LiveSubagent: View {
    let call: LiveActivity.Call
    let palette: LivePalette
    let spinner: String

    var body: some View {
        VStack(spacing: 4) {
            Text(call.agentType ?? String(localized: "subagent")).font(palette.font(12, weight: .bold)).lineLimit(1)
            Text(verbatim: call.label).foregroundStyle(palette.subagents.color).lineLimit(2).multilineTextAlignment(.center)
            Group {
                if call.running { Text(String(localized: "\(spinner) running")).foregroundStyle(palette.subagents.color) }
                else if call.failed { Text(String(localized: "× failed")).foregroundStyle(palette.danger.color) }
                else { Text(String(localized: "√ done")).foregroundStyle(palette.muted.color) }
            }
        }
    }
}

/// The files the agent last changed, each with what it did.
private struct LiveFiles: View {
    let files: [LiveActivity.Call]
    let palette: LivePalette

    var body: some View {
        VStack(spacing: 4) {
            Text(String(localized: "files · last changed")).font(palette.font(12, weight: .bold)).foregroundStyle(palette.agent.color)
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Text(verbatim: ((file.path ?? file.label) as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(file.kind == "create" ? String(localized: "new") : String(localized: "edited")).foregroundStyle(palette.muted.color)
                }
                .help(file.path ?? file.label)
            }
        }
    }
}

/// The latest calls as a trace, its title set into its frame: when, which kind, what, how it
/// ended; the newest in bold, at the foot. It fills the height it is given, with as many of the
/// latest calls as fit.
private struct LiveLog: View {
    let calls: [LiveActivity.Call]
    let palette: LivePalette
    let spinner: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
        GeometryReader { proxy in
            let shown = Array(calls.suffix(max(1, Int(proxy.size.height / Self.rowHeight))))
            VStack(alignment: .leading, spacing: 0) {
                if calls.isEmpty {
                    Text(String(localized: "no tool calls yet")).foregroundStyle(palette.muted.color)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, call in
                    row(call, newest: index == shown.count - 1).frame(height: Self.rowHeight)
                }
            }
            .animation(.easeOut(duration: 0.3), value: shown.map(\.id))
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(palette.line.color, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text(String(localized: "session log")).foregroundStyle(palette.muted.color)
                .padding(.horizontal, 6).background(palette.ground.color)
                .offset(x: 14, y: -8)
        }
    }

    private static let rowHeight: CGFloat = 20

    private func row(_ call: LiveActivity.Call, newest: Bool) -> some View {
        HStack(spacing: 8) {
            // In the person's own clock, 12- or 24-hour.
            Text(verbatim: call.time?.formatted(date: .omitted, time: .standard) ?? "--:--:--").foregroundStyle(palette.muted.color)
            Text(call.lane?.title.lowercased() ?? call.kind ?? String(localized: "tool")).fontWeight(.bold)
                .foregroundStyle(call.lane == .delegate ? palette.subagents.color : palette.log.color)
                .frame(width: 50, alignment: .leading)
            Text(verbatim: call.label).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            status(call)
        }
        .fontWeight(newest ? .bold : .regular)
        .foregroundStyle(newest ? palette.text.color : palette.text.color.opacity(0.8))
    }

    @ViewBuilder private func status(_ call: LiveActivity.Call) -> some View {
        if call.running { Text(String(localized: "\(spinner) running")).foregroundStyle(palette.tools.color) }
        else if call.failed { Text(String(localized: "failed")).foregroundStyle(palette.danger.color) }
        else { Text(String(localized: "ok")).foregroundStyle(palette.muted.color) }
    }
}

// MARK: Connectors

/// The lines between boxes: straight down, fanned out from the middle to a row of boxes, or gathered
/// from that row back to the middle; each ends in an arrowhead. While the agent works one dot runs
/// along each path.
private struct LiveConnector: View {
    enum Shape { case straight, fanOut(Int), fanIn(Int) }
    static let columnGap: CGFloat = 8

    let shape: Shape
    let palette: LivePalette
    let clock: LiveClock

    var body: some View {
        Canvas { context, size in
            let paths = Self.paths(shape, size: size)
            let color = palette.line.color
            for points in paths {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(color), lineWidth: 1)
            }
            // One arrowhead where each path ends; paths gathered into one end share it.
            for end in Set(paths.compactMap { $0.last.map { [$0.x, $0.y] } }) {
                var head = Path()
                head.move(to: CGPoint(x: end[0] - 4, y: end[1] - 6)); head.addLine(to: CGPoint(x: end[0] + 4, y: end[1] - 6))
                head.addLine(to: CGPoint(x: end[0], y: end[1])); head.closeSubpath()
                context.fill(head, with: .color(palette.agent.color))
            }
            guard clock.flowing else { return }
            for (index, points) in paths.enumerated() {
                let at = Self.point(along: points, fraction: clock.progress(offset: Double(index) / Double(max(1, paths.count))))
                context.fill(Path(ellipseIn: CGRect(x: at.x - 3.5, y: at.y - 3.5, width: 7, height: 7)), with: .color(palette.agent.color))
            }
        }
    }

    /// The column centres of `count` boxes side by side across `width`, as the row lays them out.
    private static func centres(_ count: Int, width: CGFloat) -> [CGFloat] {
        let box = (width - columnGap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { CGFloat($0) * (box + columnGap) + box / 2 }
    }

    private static func paths(_ shape: Shape, size: CGSize) -> [[CGPoint]] {
        let mid = size.width / 2, bus = size.height / 2
        switch shape {
        case .straight:
            return [[CGPoint(x: mid, y: 0), CGPoint(x: mid, y: size.height)]]
        case .fanOut(let count):
            return centres(count, width: size.width).map { x in
                [CGPoint(x: mid, y: 0), CGPoint(x: mid, y: bus), CGPoint(x: x, y: bus), CGPoint(x: x, y: size.height)]
            }
        case .fanIn(let count):
            return centres(count, width: size.width).map { x in
                [CGPoint(x: x, y: 0), CGPoint(x: x, y: bus), CGPoint(x: mid, y: bus), CGPoint(x: mid, y: size.height)]
            }
        }
    }

    /// The point a fraction of the way along a polyline, by length.
    private static func point(along points: [CGPoint], fraction: Double) -> CGPoint {
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
}
