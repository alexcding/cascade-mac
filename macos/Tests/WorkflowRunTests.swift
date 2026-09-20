import Foundation
import Testing

private actor WorkflowRunFixture: WorkflowRunService {
    var installed = true
    var decisions: [WorkflowAnalysis.Decision]
    var fails = false
    private(set) var contexts: [String] = []
    init(_ decisions: [WorkflowAnalysis.Decision] = []) { self.decisions = decisions }
    func hooks() async throws -> [String: String] { ["claude": installed ? "installed" : "absent"] }
    func setInstalled(_ value: Bool) { installed = value }
    func failAnalysis() { fails = true }
    func analyze(cli: WorkflowCLI, text: String, context: String) async throws -> WorkflowAnalysis {
        contexts.append(context)
        if fails { throw BackendError.operation("Fixture analyzer unavailable") }
        return .init(summary: "Checked", state: "done", decision: decisions.isEmpty ? .proceed : decisions.removeFirst(), reason: "Fixture")
    }
}

@MainActor private final class WorkflowTerminalFixture: WorkflowTerminal {
    var commands: [String] = []
    var revision: UInt64 = 0
    var stops = 0
    var waiting = false
    var changed = false
    var continuation: CheckedContinuation<UInt64, Error>?
    func execute(_ command: String) async throws -> UInt64 {
        commands.append(command); revision += 1
        if waiting { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return revision
    }
    func validate(after revision: UInt64) async throws {
        if changed || revision != self.revision { throw BackendError.operation("Fixture turn changed") }
    }
    func lastMessage() async -> String? { "Fixture agent output" }
    func stopStep() async throws {
        stops += 1; continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}

private let runRecipe = WorkflowRecipe(id: "recipe", name: "Review", steps: [
    .init(title: "Review {key}", command: "/review {url}"), .init(title: "Test", command: "/test")])

@MainActor @Test func workflowRunnerUsesFrozenRecipeAndOneRetryPerStep() async throws {
    let service = WorkflowRunFixture([.retry, .proceed, .proceed])
    let terminal = WorkflowTerminalFixture()
    let model = WorkflowRunViewModel(recipes: [runRecipe], service: service,
        context: { ["url": "https://example.test/REC-1", "key": "REC-1"] }, prepare: { _ in terminal })
    let run = Task { await model.run() }
    for _ in 0..<100 { if terminal.commands.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
    model.update([.init(id: "recipe", name: "Changed", steps: [.init(command: "must-not-run")])])
    await model.run() // Duplicate Run must not launch a second execution.
    await run.value
    #expect(terminal.commands == ["/review https://example.test/REC-1", "/review https://example.test/REC-1", "/test"])
    #expect(model.status == "Review completed" && model.step == 2 && !model.running)
    #expect(await service.contexts.first?.contains("Review REC-1") == true)
}

@MainActor @Test func workflowRunnerStopsForAttentionAndExhaustedRetryWithoutClaimingCompletion() async throws {
    for decisions: [WorkflowAnalysis.Decision] in [[.stop], [.retry, .retry]] {
        let terminal = WorkflowTerminalFixture()
        let model = WorkflowRunViewModel(recipes: [runRecipe], service: WorkflowRunFixture(decisions), context: { [:] }, prepare: { _ in terminal })
        await model.run()
        #expect(model.status.hasPrefix("Stopped") && !model.status.contains("completed"))
        #expect(terminal.commands == Array(repeating: "/review {url}", count: decisions.count))
    }
}

@MainActor @Test func workflowRunnerRequiresHooksAndCancellationStopsPendingAgent() async throws {
    let service = WorkflowRunFixture(), terminal = WorkflowTerminalFixture()
    var preparations = 0
    let model = WorkflowRunViewModel(recipes: [runRecipe], service: service, context: { [:] }, prepare: { _ in preparations += 1; return terminal })
    await service.setInstalled(false); await model.run()
    #expect(model.needsHooks && preparations == 0 && terminal.commands.isEmpty)
    await service.setInstalled(true); terminal.waiting = true
    let run = Task { await model.run() }
    for _ in 0..<100 { if terminal.continuation != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
    try #require(terminal.continuation != nil)
    await model.stop(); await run.value
    #expect(terminal.commands.count == 1 && terminal.stops == 1)
    #expect(model.status == "Workflow stopped" && !model.running && !model.stopping)
}

@MainActor @Test func workflowRunnerHandlesAdvisoryFailureButRejectsChangedTurns() async throws {
    let service = WorkflowRunFixture(), terminal = WorkflowTerminalFixture()
    await service.failAnalysis()
    let model = WorkflowRunViewModel(recipes: [runRecipe], service: service, context: { [:] }, prepare: { _ in terminal })
    await model.run()
    #expect(terminal.commands.count == 2 && model.status == "Review completed")
    #expect(model.error?.contains("analysis unavailable") == true)
    terminal.changed = true
    await model.run()
    #expect(terminal.commands.count == 3 && model.error == "Fixture turn changed")
    #expect(model.status == "Workflow stopped")
}

@MainActor @Test func workflowInputFramesMultilineTextAndRejectsTerminalControlInjection() throws {
    let project = Project(id: "p", name: "Project", repo: "owner/repo", color: nil, workspace: "/workspace")
    let session = WorkspaceSession(id: "s", projectId: "p", workspace: "/workspace", worktree: "/worktree", title: "Task", branch: "feature/task",
        url: "https://example.atlassian.net/browse/REC-123", createdAt: nil, pinned: false, jiraKey: "")
    #expect(WorkflowRunContext.values(project: project, session: session)["key"] == "REC-123")
    #expect(WorkflowRunContext.values(project: project, session: session)["worktree"] == "/worktree")
    #expect(try NativeWorkflowTerminal.paste("/review\nCheck tests 🦀") == "\u{1b}[200~/review\nCheck tests 🦀\u{1b}[201~")
    for invalid in ["", "bad\rcommand", "bad\u{1b}[201~", "bad\0command", String(repeating: "x", count: 65_537)] {
        #expect(throws: (any Error).self) { try NativeWorkflowTerminal.paste(invalid) }
    }
    let node = TerminalSession.WorkflowForeground(atShell: false, process: "node", processPath: "/opt/homebrew/bin/node", pgid: 2)
    #expect(!NativeWorkflowTerminal.matches(node, cli: .claude, launched: false))
    #expect(NativeWorkflowTerminal.matches(node, cli: .claude, launched: true))
    #expect(!NativeWorkflowTerminal.matches(node, cli: .codex, launched: true))
}
