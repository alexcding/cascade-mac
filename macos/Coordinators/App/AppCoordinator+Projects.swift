import Foundation

@MainActor protocol ProjectCoordinating: AnyObject {
    func ownsProject(_ id: String) -> Bool
    func applyProjectSave(_ project: Project, source: ProjectSaveSource)
    func applyProjectDeletion(_ id: String, model: ProjectPageViewModel)
}

extension AppCoordinator {
    var projectModels: [String: ProjectPageViewModel] { projectCoordinators.mapValues(\.model) }
    var projectCoordinator: ProjectCoordinator? {
        guard case .project(let id) = selection else { return nil }
        return projectCoordinators[id]
    }

    func removeMissingProjects(_ ids: Set<String>) -> [ProjectPageViewModel] {
        let removed = projectCoordinators.filter { !ids.contains($0.key) }
        for id in removed.keys { projectCoordinators.removeValue(forKey: id)?.retire(); projectRuntimes.removeValue(forKey: id) }
        if !removed.isEmpty { refreshRoot(); schedulePendingDeepLink() }
        return removed.values.map(\.model)
    }

    func prepareProject(_ project: Project, services: ProjectFeatureServices, factory: any ProjectFeatureFactory,
                        runtime: any ProjectCoordinating,
                        openPage: @escaping (OpenPageRequest) async throws -> Void,
                        session: @escaping (OpenPageRequest) -> PageSessionMark? = { _ in nil }) {
        if let existing = projectCoordinators[project.id] { existing.model.update(project); return }
        let model = factory.project(project, services: services, openPage: openPage, session: session)
        installProject(model, runtime: runtime)
    }

    @discardableResult func installProject(_ model: ProjectPageViewModel, runtime: (any ProjectCoordinating)?) -> ProjectCoordinator {
        let id = model.project.id
        if let existing = projectCoordinators[id], existing.model === model { return existing }
        projectCoordinators[id]?.retire()
        let child = projectCoordinatorFactory.project(model: model)
        let requiresRuntime = runtime != nil
        child.isOwned = { [weak self, weak runtime, weak model] in
            guard let self, let model else { return false }
            return projectCoordinators[id]?.model === model && (!requiresRuntime || runtime?.ownsProject(id) == true)
        }
        child.canPresent = { [weak self, weak runtime] in
            runtime?.ownsProject(id) == true && self?.selection == .project(id) && self?.canPresent == true
        }
        child.onEvent = { [weak self, weak model] event in
            // A retired coordinator's late event must not act on whichever model now owns the id.
            guard let self, let model, projectCoordinators[id]?.model === model else { return }
            handle(.projectEvent(event, projectID: id))
        }
        projectRuntimes[id] = runtime.map { WeakProjectRuntime(runtime: $0) }
        projectCoordinators[id] = child
        model.appearance = appearance
        model.active = selection == .project(id)
        refreshRoot()
        schedulePendingDeepLink()
        return child
    }

    func handleProjectEvent(_ event: ProjectCoordinator.Event, projectID id: String) {
        guard let model = projectCoordinators[id]?.model else { return }
        if case .presentationEnded = event { schedulePendingDeepLink(); return }
        guard let runtime = projectRuntimes[id]?.runtime, runtime.ownsProject(id) else { return }
        switch event {
        case .saved(let project, let source):
            guard project.id == id else { return }
            runtime.applyProjectSave(project, source: source)
        case .deleted(let deletedID):
            guard deletedID == id else { return }
            projectCoordinators.removeValue(forKey: id)?.retire()
            projectRuntimes.removeValue(forKey: id)
            runtime.applyProjectDeletion(id, model: model)
            if selection == .project(id) { navigate(to: .overview) }
            refreshRoot()
            schedulePendingDeepLink()
        case .presentationEnded: break
        }
    }
}
