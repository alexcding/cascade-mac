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
    func save(_ automation: Automation) async throws -> Automation {
        saveCalls.append(automation)
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
                               eventKey: sample.id, subject: sample.label, mode: "shadow", triggerMatched: true,
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
    func updateSettings(paused: Bool?, forwardWebhooks: Bool?) async throws -> AutomationSettings { settingsValue }
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
