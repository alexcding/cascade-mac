import Foundation
import Observation

@MainActor @Observable final class AutomationViewModel {
    private(set) var project: Project
    var draft: AutomationDraft {
        didSet {
            guard draft != oldValue else { return }
            saved = false
            if draft.fixVersionScript != oldValue.fixVersionScript {
                invalidatePreview()
            }
        }
    }
    private(set) var busy = false
    private(set) var saved = false
    private(set) var changedElsewhere = false
    private(set) var error: String?
    private(set) var preview: FixVersionPreview?
    private(set) var previewError: String?
    private(set) var previewing = false
    private(set) var forwardingStatus = "Status not checked"
    private var baseline: AutomationDraft
    private var latest: AutomationDraft
    @ObservationIgnored private var service: (any AutomationService)?
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var previewGeneration = UUID()
    @ObservationIgnored private var statusGeneration = UUID()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    enum Action: Equatable { case saved(Project) }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }

    init(project: Project, service: any AutomationService) {
        self.project = project; self.service = service
        let value = AutomationDraft(project)
        draft = value; baseline = value; latest = value
    }
    var dirty: Bool { draft != baseline }
    var canSave: Bool { service != nil && dirty && !busy }
    var canPreview: Bool { service != nil && !busy && !previewing && !draft.fixVersionScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func connect(_ service: (any AutomationService)?) {
        connection = UUID(); statusGeneration = UUID(); self.service = service
        invalidatePreview(); forwardingStatus = "Status not checked"
        if busy { error = "The connection changed while saving. Your draft is kept; review it after reconnecting." }
    }
    func update(_ project: Project) {
        let oldRepo = self.project.repo, oldJiraKey = self.project.jiraProjectKey
        self.project = project
        if oldRepo != project.repo { statusGeneration = UUID(); forwardingStatus = "Status not checked" }
        if oldJiraKey != project.jiraProjectKey { invalidatePreview() }
        let value = AutomationDraft(project)
        guard latest != value else { return }
        latest = value
        if dirty || busy { changedElsewhere = true }
        else { draft = value; baseline = value; changedElsewhere = false; saved = false }
    }
    func revert() {
        guard !busy else { return }
        draft = latest; baseline = latest; saved = false; error = nil; changedElsewhere = false
        invalidatePreview()
    }
    private func invalidatePreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        preview = nil; previewError = nil; previewing = false
    }
    func pause() { invalidatePreview(); statusGeneration = UUID() }
    func refreshStatus() async {
        guard let service else { return }
        guard !project.repo.isEmpty else { forwardingStatus = "Add a GitHub repository in Settings to forward events."; return }
        let token = UUID(), repo = project.repo
        statusGeneration = token; forwardingStatus = "Checking…"
        do {
            let repos = try await service.forwarders()
            guard statusGeneration == token else { return }
            forwardingStatus = repos.contains(repo) ? "Active — forwarding \(repo)" : "Not running for \(repo). Polling remains available."
        } catch { if statusGeneration == token { forwardingStatus = "Status unavailable: \(error.localizedDescription)" } }
    }
    func previewVersion() async {
        guard canPreview, let service else { return }
        let token = UUID(), value = draft.payload, id = project.id
        previewGeneration = token; previewing = true; preview = nil; previewError = nil
        let task = Task {
            defer { if previewGeneration == token { previewing = false; previewTask = nil } }
            do {
                let result = try await service.preview(projectID: id, script: value.fixVersionScript)
                guard previewGeneration == token else { return }
                preview = result
            } catch { if previewGeneration == token { previewError = error.localizedDescription } }
        }
        previewTask = task; await task.value
    }
    func save() async {
        if let saveTask { await saveTask.value; return }
        guard canSave, let service else { return }
        let token = connection, value = draft.payload, id = project.id
        busy = true; error = nil; saved = false
        let task = Task {
            defer { busy = false; saveTask = nil }
            do {
                let result = try await service.save(projectID: id, draft: value)
                guard connection == token else { return }
                project = result; latest = AutomationDraft(result); draft = latest; baseline = latest
                saved = true; changedElsewhere = false
                // Starting/stopping the forwarder happens asynchronously after the write.
                statusGeneration = UUID()
                forwardingStatus = draft.forwardWebhooks ? "Forwarding enabled. Refresh status to check the process." : "Forwarding disabled."
                onAction(.saved(result))
            } catch { if connection == token { self.error = error.localizedDescription } }
        }
        saveTask = task; await task.value
    }
    func stop() async { connect(nil); await saveTask?.value }
}
