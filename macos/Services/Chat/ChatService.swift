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

/// A chat just made: its id, and the folder it works in (nil when the backend did not say).
struct ChatCreated: Equatable, Sendable {
    let id: String
    let workingDirectory: String?
}

extension ChatServing {
    /// Every chat of a project, or of every project for nil, newest first.
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
        return (result["models"]?.array ?? []).compactMap { raw in
            guard var option = try? raw.decode(ChatModelOption.self) else { return nil }
            option.descriptor = raw
            return option
        }
    }

    /// Synara's `modelSelection`: the provider's model, and its options when there are any.
    private static func modelSelection(provider: String, model: String, options: JSONValue?) -> JSONValue {
        var selection: [String: JSONValue] = ["provider": .string(provider), "model": .string(model)]
        if let options, options != .null { selection["options"] = options }
        return .object(selection)
    }

    /// A Synara `ClientOrchestrationCommand`; answers the sequence of the last event it produced.
    @discardableResult func dispatch(_ command: JSONValue) async throws -> Int? {
        let result = try await rpc("orchestration.dispatchCommand", params: ["command": command])
        return result["sequence"]?.number.map { Int($0) }
    }

    /// Starts a chat: Synara's `thread.create`, working in `cwd`, on `provider`'s `model`. With no
    /// `cwd` the backend makes the chat a scratch folder of its own. The backend names it from its
    /// first message (it starts with Synara's generic title, which lists show as "New Chat").
    /// Answers its id and the folder it works in, as the backend reports it.
    /// `worktreePath` tags a chat started in a session's pane with the session's worktree, which is
    /// how lists know it is reached from the session. `knowledge` starts it with what that session's
    /// agent knows (Cascade's `knowledgeSource`): the backend finds the conversation and the engine
    /// forks it, or recaps it for another provider; the chat shows none of its messages.
    func createThread(projectID: String, cwd: String?, provider: String, model: String, options: JSONValue? = nil, worktreePath: String? = nil,
                      knowledge: ChatKnowledgeSource? = nil,
                      title: String = ChatProject.untitled, runtimeMode: String = "approval-required",
                      id: String = UUID().uuidString.lowercased(), now: Date = Date()) async throws -> ChatCreated {
        var command: [String: JSONValue] = [
            "type": "thread.create",
            "commandId": .string(Self.commandID()),
            "threadId": .string(id),
            "projectId": .string(projectID),
            "title": .string(title),
            "modelSelection": Self.modelSelection(provider: provider, model: model, options: options),
            "runtimeMode": .string(runtimeMode),
            "interactionMode": "default",
            "envMode": "local",
            "branch": nil,
            "worktreePath": worktreePath.map(JSONValue.string) ?? .null,
            "workingDirectory": cwd.map(JSONValue.string) ?? .null,
            "createdAt": .string(ChatTimestamp.string(now)),
        ]
        if let knowledge {
            command["knowledgeSource"] = ["provider": .string(knowledge.provider), "conversationId": .string(knowledge.conversationID)]
        }
        let result = try await rpc("orchestration.dispatchCommand", params: ["command": .object(command)])
        return ChatCreated(id: id, workingDirectory: result["workingDirectory"]?.string ?? cwd)
    }

    /// Sends `text` as the person's next message in chat `threadID`: Synara's `thread.turn.start`,
    /// on `provider`'s `model`, as the page sends one. `attachments` are what `saveAttachment`
    /// answered, each a Synara `ChatAttachment`.
    func startTurn(threadID: String, text: String, provider: String, model: String, options: JSONValue? = nil, attachments: [JSONValue] = [],
                   runtimeMode: String = "approval-required", messageID: String = UUID().uuidString.lowercased(),
                   now: Date = Date()) async throws {
        try await dispatch([
            "type": "thread.turn.start",
            "commandId": .string(Self.commandID()),
            "threadId": .string(threadID),
            "message": ["messageId": .string(messageID), "role": "user", "text": .string(text),
                        "attachments": .array(attachments)],
            "modelSelection": Self.modelSelection(provider: provider, model: model, options: options),
            "runtimeMode": .string(runtimeMode),
            "interactionMode": "default",
            "createdAt": .string(ChatTimestamp.string(now)),
        ])
    }

    /// Saves a file for chat `threadID`'s next message (`attachments.save`), answering the Synara
    /// `ChatAttachment` (`{type, id, name, mimeType, sizeBytes}`) a message carries.
    func saveAttachment(threadID: String, name: String, mimeType: String, data: Data) async throws -> JSONValue {
        let result = try await rpc("attachments.save", params: [
            "threadId": .string(threadID), "name": .string(name), "mimeType": .string(mimeType),
            "dataBase64": .string(data.base64EncodedString()),
        ])
        guard result["id"]?.string != nil else { throw BackendError.incompatible }
        return result
    }

    /// The conversation of a session's agent a chat can start knowing (`chat.sessionKnowledge`):
    /// `conversationID` when it is on disk, else the newest the agent has in `worktree`; nil when
    /// it has none yet.
    func sessionKnowledge(provider: String, worktree: String, conversationID: String?) async throws -> String? {
        var params: [String: JSONValue] = ["provider": .string(provider), "worktree": .string(worktree)]
        if let conversationID, !conversationID.isEmpty { params["conversationId"] = .string(conversationID) }
        let result = try await rpc("chat.sessionKnowledge", params: .object(params))
        return result["conversationId"]?.string
    }

    func renameThread(_ id: String, to title: String) async throws {
        try await dispatch(["type": "thread.meta.update", "commandId": .string(Self.commandID()),
                            "threadId": .string(id), "title": .string(title)])
    }

    func deleteThread(_ id: String) async throws { try await simple("thread.delete", id) }

    private func simple(_ type: String, _ id: String) async throws {
        try await dispatch(["type": .string(type), "commandId": .string(Self.commandID()), "threadId": .string(id)])
    }

    static func commandID() -> String { UUID().uuidString.lowercased() }
}

/// A session agent's conversation a new chat starts knowing: the chat provider it runs as, and its id.
struct ChatKnowledgeSource: Equatable, Sendable {
    let provider: String
    let conversationID: String
}

/// ISO 8601 with milliseconds, as Synara's `IsoDateTime` writes it.
enum ChatTimestamp {
    static func string(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
