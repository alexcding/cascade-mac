import Foundation
import Observation

/// What the project composer asks to start: the typed text and the agent to run it.
struct ProjectSessionRequest: Equatable, Sendable {
    let projectID: String
    let text: String
    let agent: SessionAgent
}

/// The project home's composer. Text is a task for the agent, or a pull request or Jira link to
/// start on, or — with Shell only — a branch name (`ProjectSessionStart`). Starting is the app's to
/// do; this model owns what the composer shows while it happens.
@MainActor @Observable final class ProjectComposerModel {
    var text = ""
    private(set) var agent: SessionAgent
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retired = false
    private var project: Project
    @ObservationIgnored private let start: (ProjectSessionRequest) async throws -> Void

    init(project: Project, agent: SessionAgent, start: @escaping (ProjectSessionRequest) async throws -> Void) {
        self.project = project; self.agent = agent; self.start = start
    }

    var placeholder: String {
        agent == .shell ? String(localized: "Branch name or URL")
            : String(localized: "Describe a task, or paste a pull request or Jira link")
    }
    var canStart: Bool {
        !retired && !busy && !project.workspace.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func select(_ agent: SessionAgent) {
        guard !retired else { return }
        self.agent = agent
    }

    func submit() async {
        guard canStart else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await start(ProjectSessionRequest(projectID: project.id, text: text, agent: agent))
            guard !retired else { return }
            text = ""
        } catch {
            if !retired { self.error = error.localizedDescription }
        }
    }

    func update(_ project: Project) {
        guard !retired else { return }
        self.project = project
    }

    func retire() { retired = true }
}
