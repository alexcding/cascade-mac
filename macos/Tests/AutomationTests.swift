import Foundation
import Testing

private actor AutomationFixture: AutomationService {
    var project: Project
    var fails = false
    private(set) var saves = 0
    private(set) var previews = 0
    init(_ project: Project) { self.project = project }
    func fail(_ value: Bool) { fails = value }
    func save(projectID: String, draft: AutomationDraft) async throws -> Project {
        saves += 1
        try await Task.sleep(for: .milliseconds(60))
        if fails { throw BackendError.operation("Fixture automation save failed") }
        project.forwardWebhooks = draft.forwardWebhooks; project.mergeTransition = draft.mergeTransition
        project.fixVersionEnabled = draft.fixVersionEnabled; project.fixVersionPrefix = draft.fixVersionPrefix
        project.fixVersionScript = draft.fixVersionScript
        return project
    }
    func preview(projectID: String, prefix: String, script: String) async throws -> FixVersionPreview {
        previews += 1
        // Deliberately ignores cancellation to exercise generation checks.
        try? await Task.sleep(for: .milliseconds(60))
        if fails { throw BackendError.operation("Fixture script error") }
        return .init(version: prefix + script, exists: true)
    }
    func forwarders() async throws -> [String] { [project.repo] }
}

@MainActor @Test func automationDraftKeepsExternalChangesSeparateAndSavesOnlyOwnedFields() async throws {
    var project = Project(id: "p", name: "Project", repo: "o/r", color: nil, workspace: "/tmp")
    let service = AutomationFixture(project)
    var received: [Project] = []
    let model = AutomationViewModel(project: project, service: service)
    model.onAction = { if case .saved(let project) = $0 { received.append(project) } }
    #expect(model.draft.forwardWebhooks && !model.dirty)
    await model.refreshStatus()
    #expect(model.forwardingStatus == "Active — forwarding o/r")
    model.draft.mergeTransition = "Local"
    project.mergeTransition = "External"; model.update(project)
    #expect(model.changedElsewhere && model.draft.mergeTransition == "Local")
    model.revert()
    #expect(model.draft.mergeTransition == "External" && !model.dirty)
    model.draft.mergeTransition = "  Done  "; model.draft.fixVersionPrefix = " ios- "
    model.draft.fixVersionScript = " return '1'; "
    let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.draft.payload)) as? [String: Any])
    #expect(Set(wire.keys) == ["forwardWebhooks", "mergeTransition", "fixVersionEnabled", "fixVersionPrefix", "fixVersionScript"])
    #expect(wire["fixVersionScript"] as? String == " return '1'; ")
    await service.fail(true); await model.save()
    #expect(model.dirty && model.error == "Fixture automation save failed" && received.isEmpty)
    await service.fail(false)
    async let one: Void = model.save()
    async let two: Void = model.save()
    await one; await two
    #expect(await service.saves == 2)
    #expect(model.saved && !model.dirty && received.count == 1)
    #expect(model.draft.mergeTransition == "Done" && model.draft.fixVersionPrefix == "ios-")
    #expect(model.forwardingStatus.contains("Forwarding enabled"))
}

@MainActor @Test func automationPreviewRejectsEditedHiddenAndDisconnectedResults() async throws {
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "")
    let service = AutomationFixture(project)
    let model = AutomationViewModel(project: project, service: service)
    model.draft.fixVersionScript = "old"
    let pending = Task { await model.previewVersion() }
    for _ in 0..<100 { if await service.previews == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
    model.draft.fixVersionScript = "new"
    await pending.value
    #expect(model.preview == nil && !model.previewing)
    await model.previewVersion()
    #expect(model.preview?.version == "new")
    model.pause()
    #expect(model.preview == nil)
    await service.fail(true); await model.previewVersion()
    #expect(model.previewError == "Fixture script error")
    model.connect(nil)
    #expect(model.previewError == nil && !model.canPreview && model.dirty)
}

@MainActor @Test func automationSaveRejectsOldConnectionAndStopDrainsWrite() async throws {
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "")
    let service = AutomationFixture(project)
    var received = 0
    let model = AutomationViewModel(project: project, service: service)
    model.onAction = { _ in received += 1 }
    model.draft.mergeTransition = "Done"
    let pending = Task { await model.save() }
    for _ in 0..<100 { if await service.saves == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
    await model.stop(); await pending.value
    #expect(received == 0 && model.dirty && !model.busy && !model.canSave)
    #expect(model.error?.contains("connection changed") == true)
    model.connect(service); await model.save()
    #expect(received == 1 && model.saved)
}
