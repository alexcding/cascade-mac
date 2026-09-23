import Foundation
import Observation

/// The dashboard's agent spend tile, built from the usage the shell store watches.
@MainActor @Observable final class DashboardUsageModel {
    private(set) var retired = false
    private(set) var tile = Tile()

    func update(_ usage: UsageSnapshot?) {
        guard !retired else { return }
        let agents = Theme.usageAgents.compactMap { agent -> (key: String, title: String, history: [UsageSnapshot.Day])? in
            let history = agent.key == "codex" ? usage?.codex?.history : usage?.claude?.history
            return history.map { (agent.key, agent.title, $0) }
        }
        var value = Tile()
        let days = agents.flatMap(\.history)
        value.month = days.reduce(0) { $0 + $1.cost }
        let tokens = days.reduce(0) { $0 + $1.tokens }
        if tokens > 0 { value.tokensLabel = "\(UsageStats.compact(tokens)) tokens" }
        if !agents.isEmpty {
            value.footnote = agents.map { "\($0.title) \(UsageStats.money($0.history.reduce(0) { $0 + $1.cost }, whole: true))" }
                .joined(separator: " · ")
        }
        value.lines = agents.map { Line(key: $0.key, costs: $0.history.map(\.cost)) }
        value.peak = max(0.01, days.map(\.cost).max() ?? 0)
        if tile != value { tile = value }
    }

    func retire() { retired = true }
}

extension DashboardUsageModel {
    struct Line: Equatable, Identifiable, Sendable {
        let key: String
        let costs: [Double]
        var id: String { key }
    }

    /// The AI spend tile.
    struct Tile: Equatable, Sendable {
        var month = 0.0
        var tokensLabel: String?
        var footnote = "No usage yet"
        var lines: [Line] = []
        /// The highest daily cost across the lines, the shared scale they are drawn on.
        var peak = 0.01
    }
}
