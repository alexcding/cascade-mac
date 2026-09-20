import Foundation
import Testing

actor SettingsFixture: SettingsService {
    var values = ["poll_interval": "60", "jira_base_url": "https://jira.test", "unrelated": "keep"]
    var writes: [[String: String]] = []
    var fails = false
    var configGate: ProjectPageGate?
    var saveGate: ProjectPageGate?
    func fail(_ value: Bool) { fails = value }
    func holdConfig(_ gate: ProjectPageGate) { configGate = gate }
    func holdSave(_ gate: ProjectPageGate) { saveGate = gate }
    func setValues(_ values: [String: String]) { self.values = values }
    func config() async throws -> [String: String] {
        let result = values
        if let gate = configGate { configGate = nil; try await gate.wait() }
        try await Task.sleep(for: .milliseconds(40))
        if fails { throw BackendError.operation("Settings offline") }
        return result
    }
    func save(_ patch: [String: String]) async throws {
        if let gate = saveGate { saveGate = nil; try await gate.wait() }
        try await Task.sleep(for: .milliseconds(40))
        if fails { throw BackendError.operation("Save failed") }
        writes.append(patch); values.merge(patch, uniquingKeysWith: { _, new in new })
    }
    func sounds() -> [ReviewSound] { [ReviewSound(name: "Glass", path: "/System/Library/Sounds/Glass.aiff")] }
}

@MainActor final class SettingsRuntimeFixture: SettingsCoordinating {
    var patches: [[String: String]] = []
    var activations = 0
    func activateSettings() { activations += 1 }
    var cleared: [BrowsingDataScope] = []
    func clearBrowsingData(_ scope: BrowsingDataScope) async { cleared.append(scope) }
    var gate: ProjectPageGate?
    func applySettingsSave(_ patch: [String: String]) async {
        patches.append(patch)
        if let gate { self.gate = nil; try? await gate.wait() }
    }
    var presentWelcomeCount = 0
    func presentWelcome() { presentWelcomeCount += 1 }
}

@MainActor func settingsFixtureModel() -> SettingsViewModel {
    NativeSettingsFeatureFactory(desktop: ProjectPageActions(), copy: { _ in }).settings()
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsPreserveDraftsSaveOnlyChangedFieldsAndRecoverAfterFailure() async throws {
    let service = SettingsFixture()
    let runtime = SettingsRuntimeFixture(), model = settingsFixtureModel()
    let coordinator = SettingsCoordinator(model: model, runtime: runtime)
    model.connect(service); model.refresh()
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.loaded && model.draft.jiraBaseURL == "https://jira.test")
    model.draft.pollInterval = "90"
    model.refresh()
    while model.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.draft.pollInterval == "90" && model.dirty)
    await service.fail(true)
    await model.save()
    #expect(model.error == "Save failed" && model.dirty && runtime.patches.isEmpty)
    await service.fail(false)
    model.refresh()
    while model.loading { await Task.yield() }
    #expect(model.saveError == "Save failed" && model.loadError == nil)
    let save = Task { await model.save() }
    try await Task.sleep(for: .milliseconds(10))
    model.draft.pollInterval = "120"
    await save.value
    await coordinator.waitForCompletion()
    #expect(await service.writes == [["poll_interval": "90"]])
    #expect(runtime.patches == [["poll_interval": "90"]] && model.draft.pollInterval == "120" && model.dirty)
    await model.stop(); model.connect(service)
    await model.save()
    #expect(!model.dirty)
    #expect(await service.values["unrelated"] == "keep")
    model.draft.jiraAPIToken = "unsaved token"
    model.revert()
    #expect(model.draft.jiraAPIToken.isEmpty && !model.dirty)
    await model.stop()
}

@Test func settingsValidateIntervalsAndSiteWithoutAddingUnrelatedConfigKeys() {
    var draft = AppConfigDraft(["unrelated": "keep"])
    draft.pollInterval = "0"
    #expect(draft.validationError != nil)
    draft.pollInterval = "90"; draft.jiraPollInterval = "not a number"
    #expect(draft.validationError != nil)
    draft.jiraPollInterval = "120"; draft.jiraLimit = "0"
    #expect(draft.validationError != nil)
    draft.jiraLimit = "100"
    for raw in ["file:///tmp", "https://user:secret@jira.test", "https://jira.test/?secret=1"] {
        draft.jiraBaseURL = raw; #expect(draft.validationError != nil)
    }
    draft.jiraBaseURL = "https://jira.test/jira"
    #expect(draft.validationError == nil && draft.values["unrelated"] == nil)
}
