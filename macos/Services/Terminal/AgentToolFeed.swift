import Foundation
import Observation

/// A terminal's agent call by call, as its tool hooks report each one the moment it starts and
/// ends (`agent-tool` events): what the Live tab draws ahead of the transcript, with the times the
/// calls really ran at, and its subagents from their start to their stop — one run in the background
/// included, which its call reports launched long before it is done. Only the agent's own calls: a
/// subagent's (`agentId` set) are its business, and never reach the session's transcript to be
/// counted against. Each call keeps the conversation
/// it was made in, so a `/clear` or `/resume` is not drawn with the last conversation's calls.
/// Hooks from before these existed, or a CLI that does not fire them, leave it empty, and the
/// transcript alone is drawn.
@MainActor @Observable final class AgentToolFeed {
    struct Call: Equatable, Identifiable, Sendable {
        let id: String
        let kind: String?
        let label: String
        let started: Date
        /// The kind of subagent a subagent call asks for.
        var agentType: String? = nil
        /// The conversation it was made in, as the hook named it.
        var conversation: String? = nil
        var ended: Date? = nil
        var failed = false
    }

    /// A subagent, by its own id: what kind it is, and when it started and stopped.
    struct Subagent: Equatable, Identifiable, Sendable {
        let id: String
        let type: String?
        let started: Date
        var conversation: String? = nil
        var ended: Date? = nil
    }

    /// What was heard in one conversation.
    struct Heard: Equatable, Sendable {
        var calls: [Call] = []
        var subagents: [Subagent] = []
    }

    /// The latest calls and subagents, oldest first.
    private(set) var calls: [Call] = []
    private(set) var subagents: [Subagent] = []
    static let limit = 40
    /// Ends heard before their starts, by id: each hook is its own process, so a quick call's end
    /// can arrive first. Taken up when the start arrives.
    @ObservationIgnored private var early: [String: (at: Date, failed: Bool)] = [:]

    func receive(_ event: ServerEvent, at now: Date = Date()) {
        guard event.type == "agent-tool", let phase = event.phase else { return }
        let conversation = event.sessionId.flatMap { $0.isEmpty ? nil : $0 }
        switch phase {
        case "subagent-start":
            guard let id = event.agentId, !subagents.contains(where: { $0.id == id }) else { return }
            var subagent = Subagent(id: id, type: event.agentType, started: now, conversation: conversation)
            subagent.ended = early.removeValue(forKey: "agent:" + id)?.at
            subagents.append(subagent)
            if subagents.count > Self.limit { subagents.removeFirst(subagents.count - Self.limit) }
            return
        case "subagent-done":
            guard let id = event.agentId else { return }
            guard let index = subagents.firstIndex(where: { $0.id == id }) else { remember("agent:" + id, at: now, failed: false); return }
            // Closed already, when its turn ended: that stays when it stopped.
            if subagents[index].ended == nil { subagents[index].ended = now }
            return
        default:
            // A subagent's own call.
            guard event.agentId == nil else { return }
        }
        switch phase {
        case "start":
            let id = event.toolUseId ?? UUID().uuidString
            guard !calls.contains(where: { $0.id == id }) else { return }
            var call = Call(id: id, kind: event.kind, label: event.label ?? event.tool ?? "", started: now,
                            agentType: event.agentType, conversation: conversation)
            if let end = early.removeValue(forKey: id) { call.ended = end.at; call.failed = end.failed }
            calls.append(call)
            if calls.count > Self.limit { calls.removeFirst(calls.count - Self.limit) }
        case "done", "failed":
            guard let id = event.toolUseId else { return }
            guard let index = calls.firstIndex(where: { $0.id == id }) else { remember(id, at: now, failed: phase == "failed"); return }
            calls[index].ended = now
            calls[index].failed = phase == "failed"
        default:
            break
        }
    }

    private func remember(_ id: String, at: Date, failed: Bool) {
        // A start that never comes leaves its end here: a few at most are kept.
        if early.count >= Self.limit { early.removeAll() }
        early[id] = (at, failed)
    }

    /// The calls and subagents of a conversation; all of them when it is not known.
    func heard(in conversation: String?) -> Heard {
        func belongs(_ named: String?) -> Bool { conversation == nil || named == nil || named == conversation }
        return Heard(calls: calls.filter { belongs($0.conversation) }, subagents: subagents.filter { belongs($0.conversation) })
    }

    /// The agent started again, took up another conversation, or ended a turn with nothing left
    /// working: a subagent it never heard stop — interrupted, killed, or the agent quit under it —
    /// runs no more.
    func closeSubagents(at now: Date = Date()) {
        for index in subagents.indices where subagents[index].ended == nil { subagents[index].ended = now }
    }

    /// Another agent in the terminal: nothing of the last one's applies.
    func reset() {
        if !calls.isEmpty { calls = [] }
        if !subagents.isEmpty { subagents = [] }
        early = [:]
    }
}
