import Foundation
import Observation

struct WorkflowAnalysis: Decodable, Equatable, Sendable {
    enum Decision: String, Decodable, Sendable { case proceed, retry, stop }
    var summary: String = ""
    var state: String = ""
    var decision: Decision = .proceed
    var reason: String = ""
}

protocol WorkflowRunService: Sendable {
    func hooks() async throws -> [String: String]
    func analyze(cli: WorkflowCLI, text: String, context: String) async throws -> WorkflowAnalysis
}

struct APIWorkflowRunService: WorkflowRunService {
    let api: APIClient
    func hooks() async throws -> [String: String] { try await api.get(Routes.AGENT_HOOKS) }
    func analyze(cli: WorkflowCLI, text: String, context: String) async throws -> WorkflowAnalysis {
        struct Input: Encodable { let cli: WorkflowCLI; let text: String; let context: String }
        return try await api.request(Routes.AGENT_ANALYZE, method: "POST", body: Input(cli: cli, text: text, context: context), timeout: 130)
    }
}

@MainActor protocol WorkflowTerminal: AnyObject {
    func execute(_ command: String) async throws -> UInt64
    func validate(after revision: UInt64) async throws
    func lastMessage() async -> String?
    func stopStep() async throws
}

@MainActor @Observable final class WorkflowRunViewModel {
    private(set) var recipes: [WorkflowRecipe]
    var selectedID: String
    private(set) var running = false
    private(set) var stopping = false
    private(set) var status = ""
    private(set) var step = 0
    private(set) var total = 0
    private(set) var error: String?
    private(set) var analysis: WorkflowAnalysis?
    private(set) var needsHooks = false
    @ObservationIgnored private let service: any WorkflowRunService
    @ObservationIgnored private let prepare: (WorkflowCLI) async throws -> any WorkflowTerminal
    @ObservationIgnored private let context: () -> [String: String]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var terminal: (any WorkflowTerminal)?

    init(recipes: [WorkflowRecipe], service: any WorkflowRunService,
         context: @escaping () -> [String: String], prepare: @escaping (WorkflowCLI) async throws -> any WorkflowTerminal) {
        self.recipes = recipes; selectedID = recipes.first?.id ?? ""
        self.service = service; self.context = context; self.prepare = prepare
    }
    var canRun: Bool { !running && !stopping && recipes.contains { $0.id == selectedID } }
    func update(_ recipes: [WorkflowRecipe]) {
        self.recipes = recipes
        if !recipes.contains(where: { $0.id == selectedID }) { selectedID = recipes.first?.id ?? "" }
    }
    func run() async {
        guard canRun, let recipe = recipes.first(where: { $0.id == selectedID }) else { return }
        let steps = recipe.steps.filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !steps.isEmpty else { error = "This workflow has no commands."; return }
        running = true; error = nil; analysis = nil; needsHooks = false; step = 0; total = steps.count
        status = "Checking \(recipe.cli.title) hooks…"
        let task = Task {
            defer { running = false; self.task = nil; terminal = nil }
            do {
                let hooks = try await service.hooks()
                try Task.checkCancellation()
                // An outdated install still reports turns, which is all a workflow listens for.
                guard ["installed", "outdated"].contains(hooks[recipe.cli.rawValue] ?? "") else {
                    needsHooks = true
                    throw BackendError.operation("Install \(recipe.cli.title) hooks in Settings → CLIs before running a workflow.")
                }
                status = "Preparing \(recipe.cli.title)…"
                let terminal = try await prepare(recipe.cli)
                self.terminal = terminal
                try Task.checkCancellation()
                let values = context()
                for (index, definition) in steps.enumerated() {
                    step = index + 1
                    let command = WorkflowText.resolve(definition.command, context: values)
                    let goal = WorkflowText.resolve(definition.title, context: values)
                    var retried = false
                    while true {
                        try Task.checkCancellation()
                        status = "\(recipe.name): step \(step)/\(total)\(retried ? " (retry)" : "") — \(goal.isEmpty ? "waiting for the agent" : goal)"
                        let revision = try await terminal.execute(command)
                        try Task.checkCancellation()
                        try await terminal.validate(after: revision)
                        status = "Checking step \(step)/\(total)…"
                        try await Task.sleep(for: .milliseconds(500))
                        try await terminal.validate(after: revision)
                        var decision = WorkflowAnalysis.Decision.proceed
                        if let text = await terminal.lastMessage(), !text.isEmpty {
                            let next = index + 1 < steps.count ? "Next step: \(steps[index + 1].title)." : "This was the last step."
                            let prompt = "Automated workflow \(recipe.name). Finished step \(step)/\(total): \(goal.isEmpty ? command : goal). \(next)"
                            do {
                                let result = try await service.analyze(cli: recipe.cli, text: text, context: prompt)
                                try Task.checkCancellation()
                                try await terminal.validate(after: revision)
                                analysis = result; decision = result.decision
                            } catch {
                                try Task.checkCancellation()
                                self.error = "Completion analysis unavailable: \(error.localizedDescription). Continuing after the Stop hook."
                            }
                        }
                        try Task.checkCancellation()
                        try await terminal.validate(after: revision)
                        if decision == .stop {
                            status = "Stopped — agent needs attention"; return
                        }
                        if decision == .retry {
                            guard !retried else { status = "Stopped after one retry of step \(step)"; return }
                            retried = true; continue
                        }
                        break
                    }
                }
                status = "\(recipe.name) completed"
            } catch is CancellationError { status = "Workflow stopped" }
            catch { self.error = error.localizedDescription; status = "Workflow stopped" }
        }
        self.task = task; await task.value
    }
    func stop() async {
        guard !stopping else { await task?.value; return }
        stopping = true
        let task = self.task, terminal = self.terminal
        task?.cancel()
        do { try await terminal?.stopStep() }
        catch { self.error = "Could not interrupt the agent: \(error.localizedDescription)" }
        await task?.value
        stopping = false
    }
}

struct WorkflowRunContext {
    static func values(project: Project, session: WorkspaceSession) -> [String: String] {
        let components = URL(string: session.url)?.path.split(separator: "/").map(String.init) ?? []
        let pull = components.firstIndex(of: "pull").flatMap { components.indices.contains($0 + 1) ? components[$0 + 1] : nil } ?? ""
        return ["url": session.url.hasPrefix("session:") ? "" : session.url,
                "key": session.jiraKey.flatMap { $0.isEmpty ? nil : $0 } ?? SessionPage.parse(session.url)?.key ?? "", "pr": pull,
                "branch": session.branch, "repo": project.repo, "workspace": session.workspace, "worktree": session.worktree]
    }
}
