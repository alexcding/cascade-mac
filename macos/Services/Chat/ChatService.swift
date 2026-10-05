import Foundation

/// The chat backend: one route, `POST /api/chat/rpc {method, params}`, answered `{result}` or
/// `{error:{message, code?}}`. Every method the page calls goes through it as it is, and the app's
/// own uses — lists, providers, creating and changing chats — are the helpers below, built on the
/// same call. A fake implements `rpc` alone.
protocol ChatServing: Sendable {
    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue
}

struct APIChatService: ChatServing {
    let api: APIClient

    func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        let body: JSONValue = ["method": .string(method), "params": params]
        let (data, status) = try await api.post(Routes.CHAT_RPC, json: body.encoded())
        let reply = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(status) else {
            if let error = reply?["error"] {
                // `{error:{message, code}}`, or a plain `{error:"…"}` from the router itself.
                if let message = error["message"]?.string { throw ChatRPCError(message: message, code: error["code"]?.string) }
                if let message = error.string { throw ChatRPCError(message: message) }
            }
            throw BackendError.http(status)
        }
        guard let reply else { throw BackendError.incompatible }
        return reply["result"] ?? .null
    }
}

extension ChatServing {
    /// Every chat of a project, or of every project for nil, newest first; archived ones included.
    func listThreads(projectID: String? = nil) async throws -> [ChatThreadShell] {
        let params: JSONValue = projectID.map { ["projectId": .string($0)] } ?? [:]
        let result = try await rpc("chat.listThreads", params: params)
        // A shell this build cannot read is left out rather than losing the whole list.
        return (result.array ?? []).compactMap { try? $0.decode(ChatThreadShell.self) }
    }

    /// The providers' statuses, whole, as the page takes them.
    func providerStatuses() async throws -> JSONValue {
        try await rpc("chat.providerStatuses", params: [:])
    }

    /// The models `provider` offers, for the new-chat picker.
    func listModels(provider: String, cwd: String?) async throws -> [ChatModelOption] {
        var params: [String: JSONValue] = ["provider": .string(provider)]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        let result = try await rpc("provider.listModels", params: .object(params))
        return (result["models"]?.array ?? []).compactMap { try? $0.decode(ChatModelOption.self) }
    }

    /// A Synara `ClientOrchestrationCommand`; answers the sequence of the last event it produced.
    @discardableResult func dispatch(_ command: JSONValue) async throws -> Int? {
        let result = try await rpc("orchestration.dispatchCommand", params: ["command": command])
        return result["sequence"]?.number.map { Int($0) }
    }

    /// Starts a chat: Synara's `thread.create`, working in `cwd`, on `provider`'s `model`. The
    /// backend names it from its first message (it starts with Synara's generic title, which lists show as "New Chat"). Answers its id.
    func createThread(projectID: String, cwd: String, provider: String, model: String,
                      title: String = ChatProject.untitled, runtimeMode: String = "approval-required",
                      id: String = UUID().uuidString.lowercased(), now: Date = Date()) async throws -> String {
        let command: JSONValue = [
            "type": "thread.create",
            "commandId": .string(Self.commandID()),
            "threadId": .string(id),
            "projectId": .string(projectID),
            "title": .string(title),
            "modelSelection": ["provider": .string(provider), "model": .string(model)],
            "runtimeMode": .string(runtimeMode),
            "interactionMode": "default",
            "envMode": "local",
            "branch": nil,
            "worktreePath": nil,
            "workingDirectory": .string(cwd),
            "createdAt": .string(ChatTimestamp.string(now)),
        ]
        try await dispatch(command)
        return id
    }

    func renameThread(_ id: String, to title: String) async throws {
        try await dispatch(["type": "thread.meta.update", "commandId": .string(Self.commandID()),
                            "threadId": .string(id), "title": .string(title)])
    }

    func archiveThread(_ id: String) async throws { try await simple("thread.archive", id) }
    func unarchiveThread(_ id: String) async throws { try await simple("thread.unarchive", id) }
    func deleteThread(_ id: String) async throws { try await simple("thread.delete", id) }

    private func simple(_ type: String, _ id: String) async throws {
        try await dispatch(["type": .string(type), "commandId": .string(Self.commandID()), "threadId": .string(id)])
    }

    static func commandID() -> String { UUID().uuidString.lowercased() }
}

/// ISO 8601 with milliseconds, as Synara's `IsoDateTime` writes it.
enum ChatTimestamp {
    static func string(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
