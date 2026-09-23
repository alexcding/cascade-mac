import Foundation
import Testing

private actor SectionLoginService: LoginItemService {
    var reads = 0, mutations = 0
    func state() -> LoginItemState { reads += 1; return .init(status: .notRegistered, registrationUnavailableReason: "Fixture") }
    func setEnabled(_ enabled: Bool) { mutations += 1 }
    func openSystemSettings() {}
}
private actor SectionFontCatalog: CodeFontCatalog {
    var reads = 0
    var gate: ProjectPageGate?
    func hold(_ gate: ProjectPageGate) { self.gate = gate }
    func families() async -> [String] {
        reads += 1
        let captured = reads
        if let gate { self.gate = nil; try? await gate.wait() }
        return ["Font \(captured)"]
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsSectionObserversOwnReadsAndForegroundPollingWithoutViews() async throws {
    let login = SectionLoginService(), fonts = SectionFontCatalog(), clis = CLIFixture()
    let diagnostics = DiagnosticsFixture(), resources = HeldResourceService()
    let model = NativeSettingsFeatureFactory(desktop: ProjectPageActions(), copy: { _ in }, loginItem: login, fontCatalog: fonts).settings()
    model.clis.connect(clis); model.diagnostics.connect(diagnostics); model.resources.connect(resources)
    let runtime = SettingsRuntimeFixture(), root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installSettings(model, runtime: runtime)
    #expect(await login.reads == 0)
    #expect(await fonts.reads == 0)
    root.setSettingsPresented(true)
    // Settings opens on General, which owns the login item and nothing that reads the backend.
    while model.loginItem.loading { await Task.yield() }
    #expect(await login.reads == 1)
    #expect(await login.mutations == 0)
    #expect(await fonts.reads == 0)
    #expect(await clis.probes == 0)
    #expect(runtime.activations == 1)
    // Text Editor owns the code font picker.
    model.section = .editor
    while model.fonts.loading { await Task.yield() }
    #expect(await fonts.reads == 1)
    #expect(await login.reads == 1)
    // Terminal shows a family picker too, so the installed-font catalogue is read for it as well.
    model.section = .terminal
    while model.fonts.loading { await Task.yield() }
    #expect(await fonts.reads == 2)
    // System carries the inspector and the resource readout together.
    model.section = .system
    while await diagnostics.calls == 0 { await Task.yield() }
    while await resources.calls == 0 { await Task.yield() }
    #expect(model.diagnostics.loading && model.resources.loading)
    // Leaving System hides both, so a late inspector response is discarded, not surfaced.
    model.section = .editor
    #expect(!model.diagnostics.loading && !model.resources.loading)
    await diagnostics.complete(1, with: .failure(BackendError.operation("Hidden response")))
    await resources.complete(.init(processes: []))
    #expect(model.diagnostics.error == nil)
    model.section = .system
    while await resources.calls < 2 { await Task.yield() }
    #expect(model.resources.loading && model.resources.updatedAt == nil)
    // Backgrounding pauses the resource poll; leaving Settings keeps it paused.
    model.applicationActiveChanged(false)
    #expect(!model.resources.loading)
    await resources.complete(.init(processes: []))
    root.setSettingsPresented(false)
    #expect(!model.active && !model.resources.loading)
    model.applicationActiveChanged(true)
    #expect(await resources.calls == 2)
    model.section = .clis
    #expect(await clis.probes == 0)
    root.setSettingsPresented(true)
    while model.clis.probing || model.clis.loadingHooks { await Task.yield() }
    #expect(await clis.probes == 1)
    #expect(runtime.activations == 2)
    // Back from a terminal that installed a tool: Integrations checks again without Refresh.
    model.applicationActiveChanged(true)
    while model.clis.probing { await Task.yield() }
    #expect(await clis.probes == 2)
    // Re-entering System started a second inspector read; resume it so retire() leaves nothing
    // suspended. Diagnostics is hidden by now, so the failure is discarded.
    await diagnostics.complete(2, with: .failure(BackendError.operation("Discarded response")))
    #expect(model.diagnostics.error == nil)
    child.retire(); await resources.close()
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsSectionChangesCancelOldFontResultsWithoutClearingReplacement() async throws {
    let catalog = SectionFontCatalog(), gate = ProjectPageGate()
    await catalog.hold(gate)
    let model = NativeSettingsFeatureFactory(desktop: ProjectPageActions(), copy: { _ in }, loginItem: SectionLoginService(), fontCatalog: catalog).settings()
    model.section = .editor
    model.setActive(true); await gate.waitForStart()
    model.section = .system
    #expect(!model.fonts.loading)
    model.section = .editor
    while model.fonts.loading { await Task.yield() }
    #expect(model.fonts.families == ["Font 2"])
    await gate.finish()
    model.section = .system; model.section = .editor
    while model.fonts.loading { await Task.yield() }
    #expect(model.fonts.families == ["Font 3"])
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func settingsCLIIntentsRequireCoordinatorOwnershipAndKeepActionErrorsSeparate() async throws {
    let actions = ProjectPageActions(), service = CLIFixture(), runtime = SettingsRuntimeFixture()
    var root: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let model = NativeSettingsFeatureFactory(desktop: actions, copy: actions.copy, loginItem: SectionLoginService(), fontCatalog: SectionFontCatalog()).settings()
    model.clis.connect(service)
    let child = try #require(root).installSettings(model, runtime: runtime)
    model.clis.copyLogin(.gh); model.clis.openGuide(.gh)
    #expect(actions.copied.isEmpty && actions.browsers.isEmpty)
    root?.setSettingsPresented(true)
    model.clis.copyLogin(.gh)
    #expect(actions.copied.isEmpty)
    model.section = .clis
    while model.clis.probing || model.clis.loadingHooks { await Task.yield() }
    root?.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    model.clis.copyLogin(.gh); model.clis.requestToggleHook(.claude)
    #expect(actions.copied.isEmpty)
    #expect(await service.mutations.isEmpty)
    root?.dismissSheet(id: try #require(root?.sheet).id)
    actions.browserSucceeds = false; model.clis.openGuide(.gh)
    #expect(model.clis.actionError != nil && model.clis.probeError == nil)
    model.clis.refresh()
    while model.clis.probing || model.clis.loadingHooks { await Task.yield() }
    #expect(model.clis.actionError != nil)
    model.clis.copyLogin(.gh)
    #expect(actions.copied == ["gh auth login"] && model.clis.actionError == nil)
    model.clis.requestToggleHook(.claude); model.clis.requestToggleHook(.claude)
    while model.clis.changing == nil { await Task.yield() }
    root?.navigate(to: .overview)
    await model.clis.waitForMutation()
    #expect(await service.mutations == ["claude"])
    #expect(model.clis.hooks["claude"] == "installed")
    let replacement = settingsFixtureModel()
    root?.installSettings(replacement, runtime: runtime)
    model.clis.copyLogin(.gh); model.clis.openGuide(.gh); model.clis.requestToggleHook(.claude)
    model.clis.connect(service); model.clis.refresh()
    #expect(child.retired && model.clis.retired && !model.clis.probing)
    #expect(actions.copied.count == 1 && actions.browsers.count == 1)
    root = nil
}
