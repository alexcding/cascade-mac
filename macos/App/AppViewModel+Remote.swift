import Foundation

/// Cascade Remote: what the iCloud mirror reads from the app, and how a message or an answer from
/// the phone gets into a session.
extension AppViewModel: RemoteMirrorHost {
    func remoteSources() -> [RemoteSource] {
        sessions.compactMap { session in
            guard let terminal = terminals["task:\(session.id)"], terminal.isLive,
                  let cli = terminal.agentTurns.cli ?? session.cli else { return nil }
            let turns = terminal.agentTurns
            let waiting = terminal.termID.flatMap { offeredPermissions[$0] }?.isEmpty == false
            let state: RemoteSession.State = waiting ? .asking : turns.busy ? .working : .idle
            return RemoteSource(id: session.id, title: session.label,
                                project: projects.first { $0.id == session.projectId }?.name,
                                cli: cli, worktree: session.worktree,
                                conversation: [turns.sessionID, session.sessionId].compactMap { $0 }.first { !$0.isEmpty },
                                state: state)
        }
    }

    func remoteTranscript(_ source: RemoteSource, since: String?) async throws -> AgentTranscript {
        try await agentTranscript(cli: source.cli, worktree: source.worktree, since: since, conversation: source.conversation)
    }

    func remoteDeliver(_ text: String, to sessionID: String) async throws -> RemoteDelivery.TurnStart? {
        guard let terminal = terminals["task:\(sessionID)"] else {
            throw RemoteCommandError(String(localized: "The session isn’t running on your Mac."))
        }
        return try await RemoteDelivery.deliver(text, to: terminal) { [weak self, weak terminal] in
            terminal?.termID.flatMap { self?.offeredPermissions[$0] }?.isEmpty == false
        }
    }

    /// Asks each live session's terminal what is in front of it. Its turn tracker then knows when
    /// the agent its hooks spoke for has exited or been replaced.
    func remoteWatchAgents() async {
        for session in sessions {
            guard let terminal = terminals["task:\(session.id)"], terminal.isLive,
                  let front = try? await terminal.foregroundProcess() else { continue }
            terminal.agentTurns.watch(foreground: front.pgid, name: front.process, atShell: front.atShell)
        }
    }

    func remoteOpenPermissions() -> Set<String> {
        Set(offeredPermissions.values.joined().map(\.id))
    }

    func remoteReleaseHeld() { releaseHeldPermissions() }

    func remoteAnswer(permission id: String, allow: Bool) async throws {
        guard let prompt = offeredPermissions.values.joined().first(where: { $0.id == id }) else {
            throw RemoteCommandError(String(localized: "That request was already answered."))
        }
        // Nobody approves what they were not shown, whatever the phone sends.
        guard !(allow && prompt.truncated) else {
            throw RemoteCommandError(String(localized: "Too long to review on iPhone. Answer it on your Mac."))
        }
        try await answerPermission(id, decision: allow ? "allow" : "deny")
    }
}
