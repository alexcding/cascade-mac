import Foundation
import Testing

@MainActor private func loadSettings(_ model: SettingsViewModel, _ service: SettingsFixture) async {
    model.connect(service); model.refresh()
    while model.loading { await Task.yield() }
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsReconnectRejectsOldReadsAndOldStopCannotClearReplacement() async throws {
    let old = SettingsFixture(), fresh = SettingsFixture(), gate = ProjectPageGate()
    let model = settingsFixtureModel()
    await old.holdConfig(gate); model.connect(old); model.refresh(); await gate.waitForStart()
    let stop = Task { await model.stop() }
    while model.loading { await Task.yield() }
    await fresh.setValues(["poll_interval": "120"])
    await loadSettings(model, fresh)
    await gate.finish(); await stop.value
    #expect(model.draft.pollInterval == "120" && model.loaded && !model.loading)
    model.draft.pollInterval = "180"
    #expect(model.canSave)
    await model.save()
    #expect(await fresh.writes == [["poll_interval": "180"]])
    #expect(await old.writes.isEmpty)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["reconnect", "replace", "leave"])
func settingsSaveCompletionHonorsModelOwnershipAndConnection(change: String) async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })), runtime = SettingsRuntimeFixture()
    let model = root.makeSettings(factory: NativeSettingsFeatureFactory(desktop: ProjectPageActions(), copy: { _ in }), runtime: runtime)
    let child = try #require(root.settingsCoordinator), service = SettingsFixture(), gate = ProjectPageGate()
    root.setSettingsPresented(true)
    await loadSettings(model, service)
    model.draft.pollInterval = "90"
    await service.holdSave(gate)
    let save = Task { await model.save() }; await gate.waitForStart()
    await model.save()
    switch change {
    case "reconnect":
        model.connect(SettingsFixture())
        model.draft.pollInterval = "150"
    case "replace": root.installSettings(settingsFixtureModel(), runtime: runtime)
    default: root.navigate(to: .overview)
    }
    await gate.finish(); await save.value; await child.waitForCompletion()
    #expect(await service.writes == [["poll_interval": "90"]])
    if change == "leave" {
        #expect(runtime.patches == [["poll_interval": "90"]] && model.saved && !model.dirty)
    } else {
        #expect(runtime.patches.isEmpty && !model.saved && model.dirty)
        if change == "reconnect" { #expect(model.draft.pollInterval == "150") }
        else {
            model.connect(service); await model.save(); model.refresh()
            #expect(model.retired && !model.canSave && !model.loading)
        }
    }
    child.retire(); root.settingsCoordinator?.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsSaveInvalidatesOlderReadsWithoutClobberingTheNextRefresh() async throws {
    let service = SettingsFixture(), first = ProjectPageGate(), second = ProjectPageGate()
    let model = settingsFixtureModel()
    await loadSettings(model, service)
    await service.holdConfig(first); model.refresh(); await first.waitForStart()
    model.draft.pollInterval = "90"
    await model.save()
    #expect(model.saved && !model.dirty)
    await service.holdConfig(second); model.refresh(); await second.waitForStart()
    await first.finish(failing: true)
    await Task.yield()
    #expect(model.loading && model.error == nil && model.draft.pollInterval == "90")
    await second.finish()
    while model.loading { await Task.yield() }
    #expect(model.draft.pollInterval == "90" && !model.dirty && model.error == nil)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsCoordinatorSerializesCompletionsAndRejectsQueuedActionsAfterReplacement() async throws {
    let runtime = SettingsRuntimeFixture(), gate = ProjectPageGate()
    var root: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = try #require(root).installSettings(settingsFixtureModel(), runtime: runtime)
    #expect(root?.installSettings(child.model, runtime: runtime) === child)
    runtime.gate = gate
    child.handle(.saved(["jira_base_url": "https://first.test"]))
    await gate.waitForStart()
    child.handle(.saved(["jira_base_url": "https://second.test"]))
    let drain = Task { await child.waitForCompletion() }
    await Task.yield()
    #expect(runtime.patches.count == 1)
    root?.installSettings(settingsFixtureModel(), runtime: runtime)
    await gate.finish(); await drain.value
    #expect(runtime.patches.count == 1 && child.retired && child.model.retired)
    let current = try #require(root?.settingsCoordinator)
    root = nil
    current.handle(.saved(["poll_interval": "90"]))
    await current.waitForCompletion()
    #expect(runtime.patches.count == 1)
    current.retire()
}

private actor SettingsLoginFixture: LoginItemService {
    func state() -> LoginItemState { .init(status: .notRegistered, registrationUnavailableReason: "Fixture") }
    func setEnabled(_ enabled: Bool) {}
    func openSystemSettings() {}
}
private struct SettingsFontFixture: CodeFontCatalog {
    func families() async -> [String] { ["Injected Mono"] }
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsFactoryUsesInjectedPlatformDependencies() async {
    let actions = ProjectPageActions()
    let factory = NativeSettingsFeatureFactory(desktop: actions, copy: actions.copyLink,
        loginItem: SettingsLoginFixture(), fontCatalog: SettingsFontFixture())
    let model = factory.settings()
    let runtime = SettingsRuntimeFixture(), coordinator = SettingsCoordinator(model: model, runtime: runtime)
    model.section = .clis; coordinator.setActive(true)
    model.clis.copyLogin(.gh); model.clis.openGuide(.gh)
    model.loginItem.refresh(); model.fonts.refresh()
    while model.loginItem.loading || model.fonts.loading { await Task.yield() }
    #expect(actions.copied == ["gh auth login"] && actions.browsers == [ManagedCLI.gh.installationGuide])
    #expect(model.loginItem.state?.registrationUnavailableReason == "Fixture" && model.fonts.families == ["Injected Mono"])
    await model.stop()
}
