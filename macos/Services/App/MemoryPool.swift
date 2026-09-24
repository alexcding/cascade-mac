import Foundation

/// How much memory one kind of background work may hold — the agents in the sessions, or the web
/// pages — before the least recently used idle one is stopped. Unlimited, the default, stops nothing.
enum MemoryLimit: String, CaseIterable, Identifiable, Sendable {
    case unlimited
    case oneGB = "1", twoGB = "2", fourGB = "4", eightGB = "8", sixteenGB = "16"

    /// A stored value this build does not know reads as the default.
    init(setting: String?) { self = setting.flatMap(Self.init(rawValue:)) ?? .unlimited }
    var id: String { rawValue }
    var bytes: UInt64? { UInt64(rawValue).map { $0 << 30 } }
    var title: String { self == .unlimited ? "Unlimited" : "\(rawValue) GB" }
}

/// Picks what a pool stops to fit its limit.
enum MemoryPool {
    struct Member<ID: Hashable>: Equatable {
        let id: ID
        /// What stopping it frees: measured, or estimated where it cannot be.
        let bytes: UInt64
        /// Whether it may be stopped now. One that may not still counts toward the total.
        let idle: Bool
    }

    /// The members to stop, in order, so the pool's measured total `used`, plus `incoming` for one
    /// about to start, fits in `limit`. `members` come least recently used first, which is the
    /// order they go in. A pool that cannot fit stops every idle member and keeps the rest.
    static func evictions<ID>(_ members: [Member<ID>], used: UInt64, incoming: UInt64 = 0, limit: MemoryLimit) -> [ID] {
        guard let limit = limit.bytes else { return [] }
        var total = used + incoming, stopping: [ID] = []
        for member in members where member.idle {
            guard total > limit else { break }
            stopping.append(member.id)
            total -= min(total, member.bytes)
        }
        return stopping
    }
}
