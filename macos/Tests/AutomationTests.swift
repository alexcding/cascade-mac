import Foundation
import Testing

private actor AutomationFixture: AutomationService {
    var automations: [Automation]
    let catalogValue: AutomationCatalog
    var settingsValue = AutomationSettings(paused: false, forwardWebhooks: false, forwarding: [], forwardable: [])
    var saveCalls: [Automation] = []
    var deleteCalls: [String] = []
    var dryRunCalls: [Automation] = []
    var runCalls: [String] = []
    private var nextID = 1

    init(automations: [Automation], catalog: AutomationCatalog) {
        self.automations = automations
        self.catalogValue = catalog
    }

    func list() async throws -> [Automation] { automations }
    func catalog() async throws -> AutomationCatalog { catalogValue }
    /// A held save stays in flight until `release()`, so a test can act while it is out.
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() { holding = true }
    func release() { holding = false; held?.resume(); held = nil }
    func save(_ automation: Automation) async throws -> Automation {
        saveCalls.append(automation)
        if holding { await withCheckedContinuation { held = $0 } }
        var stored = automation
        if stored.id.isEmpty { stored.id = "saved-\(nextID)"; nextID += 1 }
        if let index = automations.firstIndex(where: { $0.id == stored.id }) { automations[index] = stored }
        else { automations.append(stored) }
        return stored
    }
    func delete(id: String) async throws {
        deleteCalls.append(id)
        automations.removeAll { $0.id == id }
    }
    func samples(kind: String, projects: [String], jql: String) async throws -> [AutomationSample] { [] }
    func dryRun(_ automation: Automation, sample: AutomationSample, event: String?) async throws -> AutomationTrace {
        dryRunCalls.append(automation)
        return AutomationTrace(automationId: automation.id, automationName: automation.name, eventKind: "pr",
                               eventKey: sample.id, subject: sample.label, mode: "dry", triggerMatched: true,
                               triggerDetail: "matched", status: "completed", steps: [], startedAt: "t0", finishedAt: "t1")
    }
    func run(id: String, sample: AutomationSample, event: String?) async throws -> AutomationTrace {
        runCalls.append(id)
        return AutomationTrace(automationId: id, automationName: "", eventKind: "pr", eventKey: sample.id,
                               subject: sample.label, mode: "live", triggerMatched: true, triggerDetail: "matched",
                               status: "completed", steps: [], startedAt: "t0", finishedAt: "t1")
    }
    func runs(id: String?) async throws -> [AutomationTrace] { [] }
    func settings() async throws -> AutomationSettings { settingsValue }
    var fixedForwarders: [String] = []
    func fixForwarder(repo: String) async throws { fixedForwarders.append(repo) }
    func setSettings(_ value: AutomationSettings) { settingsValue = value }
    var settingsUpdates = 0
    func updateSettings(paused: Bool?, forwardWebhooks: Bool?) async throws -> AutomationSettings {
        settingsUpdates += 1
        if let paused { settingsValue.paused = paused }
        if let forwardWebhooks { settingsValue.forwardWebhooks = forwardWebhooks }
        return settingsValue
    }
}

private func fixtureCatalog() -> AutomationCatalog {
    let openedTrigger = AutomationCatalog.Node(kind: "trigger", type: "pr.opened", group: "PR", label: "PR opened",
                                               summary: "Fires when a PR opens", subject: "pr", params: [])
    let authorParam = AutomationCatalog.Param(key: "users", label: "Authors", kind: "list", options: nil,
                                              placeholder: nil, help: nil, `default`: .list(["octocat"]))
    let authorFilter = AutomationCatalog.Node(kind: "filter", type: "pr.author", group: "PR", label: "Author is",
                                              summary: "Matches the PR author", subject: "pr", params: [authorParam])
    let bodyParam = AutomationCatalog.Param(key: "body", label: "Comment", kind: "template", options: nil,
                                            placeholder: nil, help: nil, `default`: .text("LGTM"))
    let approveAction = AutomationCatalog.Node(kind: "action", type: "github.approve", group: "GitHub",
                                               label: "Approve PR", summary: "Approves the pull request", subject: "pr",
                                               params: [bodyParam])
    let template = AutomationCatalog.Template(id: "tpl-1", name: "Auto approve", summary: "Approves trusted authors",
                                              automation: Automation(name: "Auto approve", mode: .off,
                                                                     trigger: .init(types: ["pr.opened"])))
    return AutomationCatalog(triggers: [openedTrigger], filters: [authorFilter], actions: [approveAction],
                             templates: [template], variables: [])
}

private func fixtureAutomation(id: String, name: String) -> Automation {
    var automation = Automation(name: name, mode: .live, trigger: .init(types: ["pr.opened"]))
    automation.id = id
    return automation
}

@MainActor private func connectedAutomation(_ service: AutomationFixture) async -> AutomationViewModel {
    let model = AutomationViewModel()
    model.setVisible(true)
    model.connect(service)
    while model.loading { await Task.yield() }
    return model
}

@MainActor @Test func automationConnectLoadsListCatalogAndSettingsThenSelectsTheFirstAutomation() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a1", name: "First"),
                                                  fixtureAutomation(id: "a2", name: "Second")],
                                    catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    #expect(model.automations.map(\.id) == ["a1", "a2"])
    #expect(model.catalog != nil && model.settings != nil)
    #expect(model.draft?.id == "a1" && model.baseline?.id == "a1")
    await model.stop()
}

@MainActor @Test func automationEditingTheDraftNameMarksDirtyAndRevertRestoresBaseline() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a1", name: "First")], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    let baseline = try #require(model.baseline)
    var edited = try #require(model.draft)
    edited.name = "Renamed"
    model.draft = edited
    #expect(model.dirty)
    model.revert()
    #expect(model.draft == baseline && !model.dirty)
    await model.stop()
}

@MainActor @Test func automationCreateFromTemplateYieldsAnUnsavedDraftAndSaveStoresIt() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    var received: [AutomationViewModel.Action] = []
    model.onAction = { received.append($0) }
    let template = try #require(model.catalog?.templates.first)
    model.create(from: template)
    #expect(model.draft?.id == "" && model.draft?.mode == .off && model.canSave)
    await model.save()
    #expect(await service.saveCalls.count == 1)
    #expect(model.draft?.id.isEmpty == false && !model.dirty)
    #expect(received == [.saved(try #require(model.draft))])
    await model.stop()
}

@MainActor @Test func automationAddRemoveAndMoveStepsUseCatalogueDefaultsAndReorderWithinKind() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    model.create(from: nil)
    model.addStep(.filter, type: "pr.author")
    model.addStep(.filter, type: "pr.author")
    let steps = try #require(model.draft?.steps)
    #expect(steps.count == 2 && steps.allSatisfy { $0.kind == .filter && $0.type == "pr.author" })
    #expect(steps[0].params["users"] == .list(["octocat"]))
    let firstID = steps[0].id, secondID = steps[1].id
    model.moveStep(firstID, by: 1)
    #expect(model.draft?.steps.map(\.id) == [secondID, firstID])
    model.removeStep(secondID)
    #expect(model.draft?.steps.map(\.id) == [firstID])
    await model.stop()
}

@MainActor @Test func automationDryRunSendsTheUnsavedDraftAndNeverCallsRun() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    model.create(from: nil)
    model.sample = AutomationSample(id: "s1", kind: "pr", projectId: nil, number: 1, key: nil, label: "PR #1")
    await model.dryRun()
    #expect(await service.dryRunCalls.count == 1)
    #expect(await service.dryRunCalls.first?.id == "")
    #expect(await service.runCalls.isEmpty)
    #expect(model.trace != nil)
    await model.stop()
}

@MainActor @Test func automationRetiredModelIgnoresEveryEntryPoint() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a1", name: "First")], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    let draftBefore = model.draft
    model.retire()
    let saveCallsBefore = await service.saveCalls.count
    let dryRunCallsBefore = await service.dryRunCalls.count
    model.select("a1")
    model.create(from: nil)
    model.addStep(.filter, type: "pr.author")
    await model.save()
    model.sample = AutomationSample(id: "s1", kind: "pr", projectId: nil, number: 1, key: nil, label: "PR #1")
    await model.dryRun()
    #expect(model.draft == draftBefore)
    #expect(await service.saveCalls.count == saveCallsBefore)
    #expect(await service.dryRunCalls.count == dryRunCallsBefore)
    #expect(model.retired)
}

@MainActor @Test func automationCoordinatorPresentsOnlyWhenAutomationIsTheCurrentSelection() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a1", name: "First")], catalog: fixtureCatalog())
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    root.navigate(to: .automation)
    let model = root.makeAutomation(factory: NativeAutomationFeatureFactory())
    model.connect(service)
    #expect(root.automationCoordinator?.model === model)
    #expect(root.automationCoordinator?.canPresent() == true)
    root.navigate(to: .overview)
    #expect(root.automationCoordinator?.canPresent() == false)
    root.automationCoordinator?.retire()
    await model.stop()
}

@MainActor @Test func webhookForwardingRowReadsWritesAndStopsWhenRetired() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let model = WebhookForwardingViewModel()
    // Unknown until read, it shows the default: on.
    #expect(model.enabled && model.status == nil)
    model.connect(service)
    model.refresh()
    for _ in 0..<200 where model.settings == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.settings != nil && !model.enabled)
    #expect(model.status?.hasPrefix("Polling only") == true)
    await model.setEnabled(true)
    #expect(model.enabled && !model.saving)
    // On, but the extension the forwarders run is missing: the card says to install it.
    #expect(model.status(extensionInstalled: false)?.hasPrefix("Install the gh webhook extension") == true)
    #expect(model.status(extensionInstalled: true)?.hasPrefix("Install") == false)
    #expect(await service.settingsUpdates == 1)
    model.retire()
    await model.setEnabled(false)
    #expect(await service.settingsUpdates == 1 && model.enabled)
}

@MainActor @Test func webhookForwardingListsProjectsAndFixesABlockedOne() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let blocked = ForwardingProject(id: "p1", name: "Record", repo: "o/record", state: .hookExists, error: "Hook already exists")
    let running = ForwardingProject(id: "p2", name: "Cascade", repo: "o/cascade", state: .running)
    await service.setSettings(AutomationSettings(paused: false, forwardWebhooks: true, forwarding: ["o/cascade"],
                                                 forwardable: ["o/cascade", "o/record"], projects: [blocked, running]))
    let model = WebhookForwardingViewModel()
    model.connect(service)
    model.refresh()
    for _ in 0..<200 where model.settings == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.projects.map(\.repo) == ["o/record", "o/cascade"])
    #expect(WebhookForwardingViewModel.detail(blocked).label == "Blocked")
    #expect(WebhookForwardingViewModel.detail(running).tone == .success)
    #expect(model.status == "Forwarding 1 of 2 repos. Polling covers the rest.")
    let fixing = Task { await model.fix("o/record") }
    for _ in 0..<200 where await service.fixedForwarders.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await service.fixedForwarders == ["o/record"])
    #expect(model.fixing == nil && model.error == nil)
    // Retired, a fix is refused, and the pending refresh after the last one never lands.
    model.retire()
    fixing.cancel()
    await model.fix("o/record")
    #expect(await service.fixedForwarders == ["o/record"])
}

@MainActor @Test func webhookForwardingSaysWhenEveryProjectTurnedItOff() async throws {
    let service = AutomationFixture(automations: [], catalog: fixtureCatalog())
    let off = ForwardingProject(id: "p1", name: "Record", repo: "o/record", state: .disabled)
    await service.setSettings(AutomationSettings(paused: false, forwardWebhooks: true, forwarding: [], forwardable: [], projects: [off]))
    let model = WebhookForwardingViewModel()
    model.connect(service)
    model.refresh()
    for _ in 0..<200 where model.settings == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.status == "Every project has forwarding turned off in its settings.")
}

@MainActor @Test func automationUnsavedWorkSurvivesOpeningAnotherPipeline() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a1", name: "First"), fixtureAutomation(id: "a2", name: "Second")],
                                    catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    // A new pipeline, named, then a saved one opened: the new one stays listed and comes back as typed.
    model.create(from: nil)
    model.draft?.name = "Not saved yet"
    let newKey = try #require(model.openKey)
    model.select("a1")
    #expect(model.draft?.id == "a1" && !model.dirty)
    #expect(model.newDrafts.map(\.draft.name) == ["Not saved yet"])
    // An edit to a saved pipeline is set aside the same way, and marked in the list.
    model.draft?.name = "First, edited"
    model.select("a2")
    #expect(model.hasUnsavedEdits("a1") && !model.hasUnsavedEdits("a2"))
    model.select(newKey)
    #expect(model.isNew && model.draft?.name == "Not saved yet")
    model.select("a1")
    #expect(model.draft?.name == "First, edited" && model.dirty)
    model.revert()
    #expect(!model.hasUnsavedEdits("a1") && model.draft?.name == "First")
    // Saving the new one takes it out of the unsaved rows; discarding one opens the next row.
    model.select(newKey)
    await model.save()
    #expect(model.newDrafts.isEmpty && model.openKey == model.draft?.id && model.automations.count == 3)
    model.create(from: nil)
    model.revert()
    #expect(model.newDrafts.isEmpty && model.draft?.id == "a1")
    #expect(await service.saveCalls.count == 1)
    await model.stop()
}

@MainActor private func whileSaving(_ model: AutomationViewModel, _ service: AutomationFixture,
                                   _ act: () -> Void) async throws {
    await service.hold()
    let saving = Task { await model.save() }
    let deadline = ContinuousClock.now + .seconds(5)
    while await service.saveCalls.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    act()
    await service.release()
    await saving.value
}

@MainActor @Test func automationSaveLandingOnAnotherRowLeavesThatRowAndNoDuplicate() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "b", name: "B")], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    model.create(from: nil)
    model.draft?.name = "X"
    // The reply comes back after the user has moved to B.
    try await whileSaving(model, service) { model.select("b") }
    #expect(model.selectedID == "b" && model.draft?.name == "B" && !model.dirty)
    #expect(model.newDrafts.isEmpty, "the saved pipeline must not stay behind as an unsaved row")
    #expect(model.automations.map(\.name).sorted() == ["B", "X"])
    #expect(await service.saveCalls.count == 1)
    await model.stop()
}

@MainActor @Test func automationSaveKeepsWhatWasTypedWhileItWasOut() async throws {
    let service = AutomationFixture(automations: [fixtureAutomation(id: "a", name: "First")], catalog: fixtureCatalog())
    let model = await connectedAutomation(service)
    model.draft?.name = "Second"
    try await whileSaving(model, service) { model.draft?.name = "Third" }
    #expect(model.draft?.name == "Third" && model.baseline?.name == "Second")
    #expect(model.dirty && !model.saved, "the later typing is still to be saved")
    await model.stop()
}
