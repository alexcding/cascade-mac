import Foundation

enum WorkflowCLI: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
}
