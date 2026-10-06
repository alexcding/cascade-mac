import Foundation
import WebKit

/// A terminal session's conversation as the chat page reads it: read-only. The page is handed the
/// transcript as a thread (`GET /api/agent/transcript?format=thread`), and may answer the tool
/// approval the agent waits on, which goes to `POST /api/agent/permission`. Its reads of the
/// worktree (`ChatFileAccess.folderMethods`, for file-reference previews) go to the chat backend
/// with the worktree as their folder and no thread, since the transcript's is not a chat it has.
/// Anything else it asks is refused as unavailable, since the conversation is continued from the
/// terminal.
struct TranscriptPageBackend: ChatPageBackend {
    /// `{snapshotSequence, thread}` read afresh, or null for a session with no transcript.
    let read: @Sendable () async throws -> JSONValue
    /// An approval's request id and the decision as the page words it (`accept`, `acceptForSession`,
    /// `decline`, `cancel`); answers with the dispatch's `{sequence}`.
    let respond: @Sendable (_ requestID: String, _ decision: String) async throws -> JSONValue
    /// The session's worktree, the folder the page's reads are confined to.
    var worktree = ""
    /// The chat backend's RPC, for those reads; nil refuses them.
    var files: (@Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue)?

    static var unavailable: ChatRPCError {
        ChatRPCError(message: String(localized: "This conversation is continued from its terminal."), code: "unavailable")
    }

    /// What `POST /api/agent/permission` takes for one of the page's decisions; nil for none it knows.
    static func decision(_ decision: String?) -> String? {
        switch decision {
        case "accept", "acceptForSession": "allow"
        case "decline", "cancel": "deny"
        default: nil
        }
    }

    func call(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "orchestration.getThreadDetailSnapshot":
            return try await read()
        case "orchestration.dispatchCommand":
            let command = params["command"]
            guard command?["type"]?.string == "thread.approval.respond" else { throw Self.unavailable }
            guard let id = command?["requestId"]?.string, !id.isEmpty,
                  let decision = command?["decision"]?.string, Self.decision(decision) != nil
            else { throw ChatRPCError(message: String(localized: "The answer was not understood."), code: "invalid") }
            return try await respond(id, decision)
        case _ where ChatFileAccess.folderMethods.contains(method):
            guard let files, !worktree.isEmpty, case .object(var object) = params else { throw Self.unavailable }
            object["threadId"] = nil
            object["cwd"] = .string(worktree)
            return try await files(method, .object(object))
        default:
            throw Self.unavailable
        }
    }

    /// None: the page has no composer to pick a provider in.
    func providers() async throws -> JSONValue { [] }
    func snapshot(threadID: String) async throws -> JSONValue { try await read() }
}
