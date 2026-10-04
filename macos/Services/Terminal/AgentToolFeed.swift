import Foundation
import Observation

/// A terminal's agent call by call, as its tool hooks report each one the moment it starts and
/// ends (`agent-tool` events): what the Live tab draws ahead of the transcript, with the times the
/// calls really ran at. Only the agent's own calls: a subagent's (`agentId` set) are its business,
/// and never reach the session's transcript to be counted against. Each call keeps the conversation
/// it was made in, so a `/clear` or `/resume` is not drawn with the last conversation's calls.
/// Hooks from before these existed, or a CLI that does not fire them, leave it empty, and the
/// transcript alone is drawn.
@MainActor @Observable final class AgentToolFeed {
    struct Call: Equatable, Identifiable, Sendable {
        let id: String
        let kind: String?
        let label: String
        let started: Date
        /// The conversation it was made in, as the hook named it.
        var conversation: String? = nil
        var ended: Date? = nil
        var failed = false
    }

    /// The latest calls, oldest first.
    private(set) var calls: [Call] = []
    static let limit = 40

    func receive(_ event: ServerEvent, at now: Date = Date()) {
        guard event.type == "agent-tool", event.agentId == nil, let phase = event.phase else { return }
        switch phase {
        case "start":
            let id = event.toolUseId ?? UUID().uuidString
            guard !calls.contains(where: { $0.id == id }) else { return }
            calls.append(Call(id: id, kind: event.kind, label: event.label ?? event.tool ?? "", started: now,
                              conversation: event.sessionId.flatMap { $0.isEmpty ? nil : $0 }))
            if calls.count > Self.limit { calls.removeFirst(calls.count - Self.limit) }
        case "done", "failed":
            guard let id = event.toolUseId, let index = calls.firstIndex(where: { $0.id == id }) else { return }
            calls[index].ended = now
            calls[index].failed = phase == "failed"
        default:
            break
        }
    }

    /// The calls made in a conversation; all of them when it is not known.
    func calls(in conversation: String?) -> [Call] {
        guard let conversation else { return calls }
        return calls.filter { $0.conversation == nil || $0.conversation == conversation }
    }

    /// Another agent in the terminal: nothing of the last one's applies.
    func reset() {
        if !calls.isEmpty { calls = [] }
    }
}
