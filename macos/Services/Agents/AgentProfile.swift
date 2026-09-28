import Foundation

/// What the app may count on from an agent's CLI, as the backend's adapter for it reports
/// (`Profile` in `crates/cascade-backend/src/agents/mod.rs`). The app goes by this, never by which
/// CLI it is.
struct AgentProfile: Decodable, Equatable, Sendable {
    /// The name sessions, hooks and requests carry.
    let id: String
    /// It keeps a message typed while it works and takes it in, mid-turn or after.
    let queuesMidTurn: Bool
}
