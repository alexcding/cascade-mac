import Foundation
import Testing

@MainActor private final class ProjectRuntimeFixture: ProjectCoordinating {
    var ids: Set<String> = ["p"]
    var saves: [(Project, ProjectSaveSource)] = []
    var deletions: [String] = []
    weak var coordinator: AppCoordinator?
    func ownsProject(_ id: String) -> Bool { ids.contains(id) }
    func applyProjectSave(_ project: Project, source: ProjectSaveSource) {
        saves.append((project, source))
        coordinator?.projectModels[project.id]?.update(project)
    }
    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel) { ids.remove(id); deletions.append(id) }
}

@MainActor private final class CountingProjectFeatureFactory: ProjectFeatureFactory {
    let native = NativeProjectFeatureFactory(creation: NativeCreationFlowFactory(chooseFolder: { "/tmp/injected-project" }))
    var creations = 0
    func project(_ project: Project, services: ProjectFeatureServices,
                 openPage: @escaping (OpenPageRequest) async throws -> Void) -> ProjectPageViewModel {
        creations += 1
        return native.project(project, services: services, openPage: openPage)
    }
}

@MainActor private func projectCoordinatorServices() throws -> ProjectFeatureServices {
    let baseURL = URL(string: "http://127.0.0.1:12345")!
    let api = try APIClient(baseURL: baseURL)
    return ProjectFeatureServices(projects: APIProjectService(api: api), tickets: APIJiraService(api: api),
        workflows: APIWorkflowService(api: api), automation: APIAutomationService(api: api), api: api, baseURL: baseURL)
}

@MainActor @Test func projectCoordinatorFactoryRetainsDraftsAndSharesSectionRoutes() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ProjectRuntimeFixture(); runtime.coordinator = root
    let factory = CountingProjectFeatureFactory(), services = try projectCoordinatorServices()
    var project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp")
    root.prepareProject(project, services: services, factory: factory, runtime: runtime, openPage: { _ in })
    let model = try #require(root.projectModels[project.id])
    root.navigate(to: .project(project.id))
    model.selectSection(.settings)
    #expect(root.projectCoordinator?.model === model && model.section == .settings)
    #expect(model.board?.projectID == "p")
    #expect(model.tickets != nil && model.workflows != nil && model.automation != nil)
    await model.editor.pickFolder()
    #expect(model.editor.draft.workspace == "/tmp/injected-project")
    model.editor.draft.name = "Keep this draft"
    root.navigate(to: .overview)
    project = Project(id: "p", name: "External update", repo: "", color: nil, workspace: "/tmp")
    root.prepareProject(project, services: services, factory: factory, runtime: runtime, openPage: { _ in })
    root.navigate(to: .project(project.id))
    #expect(factory.creations == 1 && root.projectModels[project.id] === model)
    #expect(model.editor.draft.name == "Keep this draft" && model.project.name == "External update")
    #expect(model.section == .settings)
    #expect(root.projectCoordinator?.navigate(to: DeepLink(.projectSection(.workflows))) == true)
    #expect(model.section == .workflows)
    model.workflows?.onAction(.saved(project))
    model.automation?.onAction(.saved(project))
    model.editor.onAction(.saved(project))
    #expect(runtime.saves.map(\.1) == [.workflows, .automation, .configuration])
    #expect(model.editor.draft.name == "Keep this draft")
}

@MainActor @Test func projectCoordinatorRejectsObsoleteCompletionAndPreservesUnrelatedNavigationOnDelete() throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ProjectRuntimeFixture(); runtime.coordinator = root
    let factory = CountingProjectFeatureFactory(), services = try projectCoordinatorServices()
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp")
    root.prepareProject(project, services: services, factory: factory, runtime: runtime, openPage: { _ in })
    let obsolete = try #require(root.projectCoordinators[project.id])
    let replacement = factory.project(project, services: services, openPage: { _ in })
    let current = root.installProject(replacement, runtime: runtime)
    obsolete.model.editor.onAction(.saved(project))
    obsolete.model.editor.onAction(.deleted(project.id))
    #expect(runtime.saves.isEmpty && runtime.deletions.isEmpty)
    current.model.editor.onAction(.deleted("another-project"))
    let other = Project(id: "other", name: "Other", repo: "", color: nil, workspace: "/tmp")
    current.model.editor.onAction(.saved(other))
    #expect(runtime.saves.isEmpty && runtime.deletions.isEmpty)
    root.navigate(to: .terminal)
    current.model.editor.onAction(.saved(project))
    #expect(runtime.saves.count == 1 && root.selection == .terminal)
    current.model.editor.onAction(.deleted(project.id))
    #expect(runtime.deletions == [project.id] && root.projectModels.isEmpty && root.selection == .terminal)
    runtime.ids.insert(project.id)
    current.model.editor.onAction(.saved(project))
    #expect(runtime.saves.count == 1)
}

@MainActor @Test func projectActionRebindingForwardsCurrentCallbackWithoutRetainingParent() throws {
    let factory = CountingProjectFeatureFactory(), services = try projectCoordinatorServices()
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp")
    var model: ProjectPageViewModel? = factory.project(project, services: services, openPage: { _ in })
    weak var released = model
    let editor = try #require(model?.editor), workflows = try #require(model?.workflows), automation = try #require(model?.automation)
    var first = 0, actions: [ProjectPageViewModel.Action] = []
    model?.onAction = { _ in first += 1 }
    editor.onAction(.saved(project))
    model?.onAction = { actions.append($0) }
    editor.onAction(.saved(project)); workflows.onAction(.saved(project)); automation.onAction(.saved(project))
    #expect(first == 1 && actions == [.saved(project, .configuration), .saved(project, .workflows), .saved(project, .automation)])
    model = nil
    #expect(released == nil)
}

@MainActor @Test func projectSnapshotRemovalRetiresCoordinatorAndRecreatedProjectGetsFreshModels() throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = ProjectRuntimeFixture(), factory = CountingProjectFeatureFactory(), services = try projectCoordinatorServices()
    let project = Project(id: "p", name: "Project", repo: "", color: nil, workspace: "/tmp")
    root.prepareProject(project, services: services, factory: factory, runtime: runtime, openPage: { _ in })
    let original = try #require(root.projectModels[project.id])
    original.editor.draft.name = "Old draft"
    #expect(root.removeMissingProjects([project.id]).isEmpty)
    #expect(root.removeMissingProjects([]).first === original && root.projectModels.isEmpty)
    original.editor.onAction(.saved(project))
    #expect(runtime.saves.isEmpty)
    root.prepareProject(project, services: services, factory: factory, runtime: runtime, openPage: { _ in })
    #expect(factory.creations == 2 && root.projectModels[project.id] !== original)
    #expect(root.projectModels[project.id]?.editor.draft.name == "Project")
    root.navigate(to: .project(project.id))
    root.projectModels[project.id]?.editor.onAction(.deleted(project.id))
    #expect(root.selection == .overview && runtime.deletions == [project.id])
}
