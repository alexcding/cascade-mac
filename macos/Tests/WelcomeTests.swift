import Foundation
import Testing

actor WelcomeCLIFixture: CLISettingsService {
    let availability: [String: CLIAvailability]
    let hookStatuses: [String: String]
    init(availability: [String: CLIAvailability] = [:], hookStatuses: [String: String] = [:]) {
        self.availability = availability; self.hookStatuses = hookStatuses
    }
    func probe() async throws -> [String: CLIAvailability] { availability }
    func hooks() async throws -> [String: String] { hookStatuses }
    func setHook(_ cli: ManagedCLI, installed: Bool) async throws -> [String: String] { hookStatuses }
}

@MainActor func makeWelcomeModel() -> WelcomeViewModel {
    WelcomeViewModel(clis: CLISettingsViewModel(copy: { _ in }, openBrowser: { _ in true }))
}

@MainActor func waitForWelcomeConnect(_ model: WelcomeViewModel) async {
    while model.clis.probing || model.clis.loadingHooks { await Task.yield() }
}

@MainActor @Test func welcomePagesWalkForwardAndBackAndStopAtTheEnds() {
    let model = makeWelcomeModel()
    #expect(model.page == .welcome && model.isFirst && !model.isLast)
    model.next(); model.next(); model.next()
    #expect(model.page == .simulator && !model.isLast)
    model.next()
    #expect(model.page == .done && model.isLast)
    model.next()
    #expect(model.page == .done)
    model.back(); model.back(); model.back(); model.back()
    #expect(model.page == .welcome && model.isFirst)
    model.back()
    #expect(model.page == .welcome)
}

@MainActor @Test func welcomeSimulatorPreviewIsReportedButNeverListedAsRemaining() async {
    let model = makeWelcomeModel()
    #expect(model.simulatorPreviewReady == nil, "unknown until the probe answers")
    model.connect(WelcomeCLIFixture(availability: ["serveSim": CLIAvailability(present: false, needs: "node"),
                                                   "node": CLIAvailability(present: false)]))
    await waitForWelcomeConnect(model)
    #expect(model.simulatorPreviewReady == false)
    #expect(model.remaining.isEmpty, "optional: a Mac without Node is still all set")
    model.connect(WelcomeCLIFixture(availability: ["serveSim": CLIAvailability(present: true, source: "npx")]))
    await waitForWelcomeConnect(model)
    #expect(model.simulatorPreviewReady == true)
}

@MainActor @Test func welcomeConnectRefreshesAvailabilityAndHooks() async {
    let model = makeWelcomeModel()
    let service = WelcomeCLIFixture(availability: ["gh": CLIAvailability(present: true, authed: true)],
        hookStatuses: ["claude": "installed"])
    model.connect(service)
    await waitForWelcomeConnect(model)
    #expect(model.clis.availability["gh"]?.present == true)
    #expect(model.clis.hooks["claude"] == "installed")
}

@MainActor @Test func welcomeCanChangeHookAndStatusLineFollowClaudePresence() async {
    let model = makeWelcomeModel()
    let absent = WelcomeCLIFixture(availability: ["claude": CLIAvailability(present: false)])
    model.connect(absent)
    await waitForWelcomeConnect(model)
    #expect(!model.canChangeHook(.claude) && !model.canChangeStatusLine)
    let present = WelcomeCLIFixture(availability: ["claude": CLIAvailability(present: true)],
        hookStatuses: ["claude": "installed", WelcomeCLIFixture.statusLineKey: "installed"])
    model.connect(present)
    await waitForWelcomeConnect(model)
    #expect(model.canChangeHook(.claude) && model.canChangeStatusLine)
}

@MainActor @Test func welcomeRemainingListsWhatIsStillOpenAndIsEmptyWhenSetUp() async {
    let model = makeWelcomeModel()
    let mixed = WelcomeCLIFixture(availability: [
        "claude": CLIAvailability(present: true),
        "codex": CLIAvailability(present: true),
        "gh": CLIAvailability(present: false),
        "ghWebhook": CLIAvailability(present: true),
        "acli": CLIAvailability(present: true, authed: false),
    ], hookStatuses: ["claude": "installed", "codex": "absent", WelcomeCLIFixture.statusLineKey: "missing"])
    model.connect(mixed)
    await waitForWelcomeConnect(model)
    #expect(model.remaining == ["GitHub CLI is not installed.", "Atlassian CLI is not signed in.", "Codex hooks are not installed.",
                                "The Claude Code context status line is not installed."])
    let clean = WelcomeCLIFixture(availability: [
        "claude": CLIAvailability(present: true),
        "codex": CLIAvailability(present: true),
        "gh": CLIAvailability(present: true, authed: true),
        "ghWebhook": CLIAvailability(present: true),
        "acli": CLIAvailability(present: true, authed: true),
    ], hookStatuses: ["claude": "installed", "codex": "installed", WelcomeCLIFixture.statusLineKey: "installed"])
    model.connect(clean)
    await waitForWelcomeConnect(model)
    #expect(model.remaining.isEmpty)
}

@MainActor @Test func welcomeFinishEmitsAndRetireSilencesEveryEntryPoint() async {
    var actions: [WelcomeViewModel.Action] = []
    let model = makeWelcomeModel()
    model.onAction = { actions.append($0) }
    model.finish()
    #expect(actions == [.finished])
    actions = []
    model.retire()
    model.next(); model.back(); model.finish(); model.connect(WelcomeCLIFixture())
    #expect(actions.isEmpty && model.page == .welcome && model.clis.retired)
}

@MainActor @Test func welcomeCLIActionArrivesWrappedOnWelcomesOnAction() {
    let model = makeWelcomeModel()
    var actions: [WelcomeViewModel.Action] = []
    model.onAction = { actions.append($0) }
    model.clis.copyLogin(.gh)
    #expect(actions == [.cli(.copyLogin(.gh))])
}

@MainActor @Test func welcomeStoresDefaultAndRoundTripThroughUserDefaults() {
    #expect(TransientWelcomeStore().shown)
    let suiteName = "WelcomeTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsWelcomeStore(preferences: preferences)
    #expect(!store.shown)
    store.shown = true
    #expect(preferences.bool(forKey: "native.welcomeShown"))
    #expect(UserDefaultsWelcomeStore(preferences: preferences).shown)
}

@MainActor @Test func appCoordinatorPresentWelcomeGatesAndDismissesLikeOtherSheets() throws {
    let coordinator = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    #expect(coordinator.presentWelcome { makeWelcomeModel() })
    let first = try #require(coordinator.welcomeModel)
    #expect(!coordinator.presentWelcome { makeWelcomeModel() })
    first.finish()
    #expect(coordinator.sheet == nil && first.retired)
    #expect(coordinator.presentWelcome { makeWelcomeModel() })
    let second = try #require(coordinator.welcomeModel)
    let sheetID = try #require(coordinator.sheet).id
    coordinator.dismissSheet(id: sheetID)
    #expect(coordinator.sheet == nil && second.retired)
}

/// The button sits on the Integrations page, and the coordinator holds it to that.
@MainActor @Test func settingsCoordinatorReachesRuntimeOnlyFromIntegrations() {
    let runtime = SettingsRuntimeFixture(), model = settingsFixtureModel()
    // The model reports to its coordinator weakly, so the test keeps it alive.
    let coordinator = SettingsCoordinator(model: model, runtime: runtime)
    defer { withExtendedLifetime(coordinator) {} }
    model.setActive(true)
    model.section = .clis
    model.clis.showWelcome()
    #expect(runtime.presentWelcomeCount == 1)
    model.section = .general
    model.clis.showWelcome()
    #expect(runtime.presentWelcomeCount == 1)
    model.section = .clis
    model.setActive(false)
    model.clis.showWelcome()
    #expect(runtime.presentWelcomeCount == 1)
}
