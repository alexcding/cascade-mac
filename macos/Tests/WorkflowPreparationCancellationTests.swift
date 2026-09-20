import Foundation
import Testing

private final class CreationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var recorded = false
    var started: Bool { lock.withLock { began } }
    var saved: Bool { lock.withLock { recorded } }
    func begin() { lock.withLock { began = true } }
    func save() { lock.withLock { recorded = true } }
}

private final class DelayedWorkflowCreation: URLProtocol, @unchecked Sendable {
    static let probe = CreationProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url!.path {
        case Routes.JIRA_SEARCH: body = #"{"items":[{"summary":"Cancel checkout"}]}"#
        case Routes.GIT_REFS: body = #"{"branches":[{"name":"main"}],"defaultBranch":"main"}"#
        case Routes.WORKTREE:
            if request.httpMethod == "POST" {
                Self.probe.begin()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                    respond(#"{"path":"/tmp/workflow-cancel"}"#)
                }
                return
            }
            // The branch has no checkout until the POST makes one; afterwards the exact-branch check finds it.
            if request.url!.query?.contains("branch=") == true, Self.probe.started {
                body = #"{"matched":true,"isWorktree":true,"branch":"feature/rec-7-cancel-checkout","path":"/tmp/workflow-cancel"}"#
            } else { body = #"{"matched":false,"isWorktree":false,"branch":"","path":""}"# }
        case Routes.TASKS:
            Self.probe.save(); body = #"{"ok":true}"#
        default: body = #"{}"#
        }
        respond(body)
    }
    private func respond(_ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func workflowPageCancellationDrainsStartedCheckoutAndSavesRecoverableShellSession() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DelayedWorkflowCreation.self]
    let api = try APIClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: URLSession(configuration: configuration))
    var project = Project(id: "fixture", name: "Fixture", repo: "", color: nil, workspace: "/tmp/fixture")
    project.jiraProjectKey = "REC"
    let target = try #require(WorkflowPageTarget.resolve(url: "https://jira.test/browse/REC-7", projects: [project]))
    let captured = project
    let task = Task { try await APIWorkflowPagePreparation(operations: SessionOperations(api: api)).prepare(target, project: captured) }
    for _ in 0..<100 {
        if DelayedWorkflowCreation.probe.started { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(DelayedWorkflowCreation.probe.started)
    task.cancel()
    let session = try await task.value
    #expect(DelayedWorkflowCreation.probe.saved)
    #expect(session.worktree == "/tmp/workflow-cancel" && session.cli == "" && session.sessionId == "")
}
