import Foundation

/// An agent CLI that Cascade launches in a terminal and hears turn hooks from.
enum AgentCLI: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}
