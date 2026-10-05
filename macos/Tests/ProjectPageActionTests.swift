import Foundation
import Testing

actor ProjectPageGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(failing: Bool = false) {
        let pending = continuation; continuation = nil
        if failing { pending?.resume(throwing: BackendError.operation("Late open failure")) }
        else { pending?.resume() }
    }
}

@MainActor final class ProjectPageActions: PageActionServing, DesktopActions {
    var opened: [OpenPageRequest] = [], navigated: [String] = [], copied: [String] = [], browsers: [URL] = []
    var browserSucceeds = true, failOpen = false
    var gate: ProjectPageGate?
    func openPage(_ request: OpenPageRequest) async throws {
        opened.append(request)
        if let gate { self.gate = nil; try await gate.wait() }
        try Task.checkCancellation()
        if failOpen { throw BackendError.operation("Fixture open failed") }
        navigated.append(request.url)
    }
    func openBrowser(_ url: URL) -> Bool { browsers.append(url); return browserSucceeds }
    func copy(_ value: String) { copied.append(value) }
    func reveal(_ url: URL) {}
}

struct ProjectPageService: ProjectService {
    func load(_ id: String) throws -> Project { throw CancellationError() }
    func save(_ draft: ProjectDraft, id: String?) throws -> Project { throw CancellationError() }
    func delete(_ id: String) {}
    func detectRepository(_ path: String) -> String { "" }
}

@MainActor final class ProjectPageRuntime: ProjectCoordinating {
    var owns = true
    func ownsProject(_ id: String) -> Bool { owns }
    func applyProjectSave(_ project: Project, source: ProjectSaveSource) {}
    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel) {}
    func projectSessionCreated(_ session: WorkspaceSession, prompt: String?, launch: AgentLaunchChoice?) {}
}
