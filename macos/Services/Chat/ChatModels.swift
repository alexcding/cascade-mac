import Foundation

/// The project id a chat with no Cascade project is filed under: Synara's `ProjectId` must not be
/// empty. A project's chat carries the project's UUID.
enum ChatProject {
    static let standalone = "cascade-standalone"
    /// Synara's generic title. A chat created with it is named from its first message by the
    /// backend; until then lists call it "New Chat".
    static let untitled = "New thread"
}

/// A chat as lists show it: Synara's `OrchestrationThreadShell`, read for the few fields the app
/// draws. Everything else in the shell is the page's, and the app never looks at it.
struct ChatThreadShell: Decodable, Equatable, Identifiable, Sendable {
    struct ModelSelection: Decodable, Equatable, Sendable {
        let provider: String
        let model: String
    }
    struct LatestTurn: Decodable, Equatable, Sendable {
        let state: String
    }
    struct Session: Decodable, Equatable, Sendable {
        let status: String
        var lastError: String? = nil
    }

    let id: String
    let projectId: String
    var title: String
    var modelSelection: ModelSelection?
    var runtimeMode: String? = nil
    var workingDirectory: String? = nil
    var worktreePath: String? = nil
    var createdAt: String? = nil
    var updatedAt: String? = nil
    var archivedAt: String? = nil
    var latestTurn: LatestTurn? = nil
    var session: Session? = nil
    var hasPendingApprovals: Bool? = nil
    var hasPendingUserInput: Bool? = nil
    /// Set on a subagent's thread: the chat whose agent ran it. Such a thread is reached from its
    /// parent's page, never listed, and read-only (it follows its parent's agent).
    var parentThreadId: String? = nil

    /// The folder the agent works in: the one it was created with, else its worktree.
    var cwd: String { workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? worktreePath ?? "" }
    var archived: Bool { archivedAt?.isEmpty == false }
    var standalone: Bool { projectId == ChatProject.standalone }
    /// It works in a private folder the backend made (`<data>/chat/workspaces/<id>`: its own, or its
    /// fork source's), which is nothing to show as a place.
    var inScratchFolder: Bool {
        let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent()
        return !cwd.isEmpty && parent.lastPathComponent == "workspaces"
            && parent.deletingLastPathComponent().lastPathComponent == "chat"
    }
    /// A subagent's thread, which its parent's page opens.
    var subagent: Bool { parentThreadId?.isEmpty == false }
    /// The CLI that answers it, as the app's drivers know it.
    var cli: String? { AgentDrivers.of(chatProvider: modelSelection?.provider)?.cli }
    /// A turn is under way.
    var working: Bool { latestTurn?.state == "running" || session?.status == "running" || session?.status == "starting" }
    /// An approval or a question waits on the person.
    var needsInput: Bool { hasPendingApprovals == true || hasPendingUserInput == true }
    /// What lists call it: its title, or "New Chat" until it has one.
    var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == ChatProject.untitled ? String(localized: "New Chat") : trimmed
    }
}

/// A provider as `chat.providerStatuses` reports it: Synara's `ServerProviderStatus`, read for
/// whether the app can start a chat on it. The page gets the statuses whole.
struct ChatProviderStatus: Decodable, Equatable, Sendable {
    var provider: String?
    var driver: String?
    var displayName: String?
    var enabled: Bool?
    var status: String?
    var available: Bool
    var authStatus: String?
    var version: String?
    var message: String?
    var models: [ChatModelOption]?

    /// The provider's kind: `driver`, or `provider` from an older shape.
    var kind: String? { driver ?? provider }
    var usable: Bool { available && enabled != false }
}

/// One model a provider offers, as `provider.listModels` describes it.
struct ChatModelOption: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let slug: String
    var name: String?
    var isDefault: Bool?
    var id: String { slug }
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? slug }
}

/// The backend refused a chat request: its message, and Synara's code when it gave one
/// (`invalid` for a command the decider rejected, `unavailable` for a method it does not serve).
struct ChatRPCError: LocalizedError, Equatable, Sendable {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }

    /// The reply the page's bridge expects for this failure.
    var reply: JSONValue {
        var error: [String: JSONValue] = ["message": .string(message)]
        if let code { error["code"] = .string(code) }
        return ["ok": false, "error": .object(error)]
    }
}
