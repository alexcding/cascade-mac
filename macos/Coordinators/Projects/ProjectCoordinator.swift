import Foundation
import Observation

@MainActor protocol ProjectCoordinatorFactory {
    func project(model: ProjectPageViewModel) -> ProjectCoordinator
}

@MainActor struct NativeProjectCoordinatorFactory: ProjectCoordinatorFactory {
    func project(model: ProjectPageViewModel) -> ProjectCoordinator { ProjectCoordinator(model: model) }
}

/// Consumes the project-owned remainder after the root has selected its project.
@MainActor @Observable final class ProjectCoordinator: Coordinatable {
    /// Lifecycle events the parent needs: a save, a deletion, the end of a presentation, or a
    /// session Start made.
    enum Event {
        case saved(Project, ProjectSaveSource), deleted(String), presentationEnded, sessionCreated(WorkspaceSession, prompt: String?, launch: AgentLaunchChoice?)
    }
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: ProjectPageViewModel
    private(set) var deletionConfirmation: ProjectEditorViewModel.DeletionRequest?
    private(set) var deleting = false
    /// Why removing the project's sessions stopped short; the project is then kept.
    private(set) var removalError: String?
    private(set) var retired = false
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    /// Removes the project's sessions, worktrees and all, before the project goes.
    @ObservationIgnored var removeSessions: (String) async throws -> Void = { _ in }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var isOwned: () -> Bool = { true }
    var isPresenting: Bool { deletionConfirmation != nil || deleting }
    init(model: ProjectPageViewModel) {
        self.model = model
        root = .project(model)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    /// The page is one screen: nothing is pushed on it.
    func navigate(to route: Route) {}
    func handle(_ action: Action) {
        if case .project(let action) = action { handle(action) } else { self.action?(action) }
    }

    func handle(_ action: ProjectPageViewModel.Action) {
        guard !retired, isOwned() else { return }
        switch action {
        case .saved(let project, let source): onEvent(.saved(project, source))
        case .sessionCreated(let session, let prompt, let launch): onEvent(.sessionCreated(session, prompt: prompt, launch: launch))
        case .deleted(let id):
            guard id == model.project.id else { return }
            deletionConfirmation = nil
            onEvent(.deleted(id))
        case .requestDeletion(let request):
            guard !isPresenting, canPresent(), model.editor.canDelete(request) else { return }
            deletionConfirmation = request
        }
    }

    func cancelDeletion(id: UUID) {
        guard deletionConfirmation?.id == id, !deleting else { return }
        endPresentation()
    }

    func confirmDeletion(id: UUID) async {
        guard !retired, !deleting, let request = deletionConfirmation, request.id == id else { return }
        guard isOwned(), model.editor.canDelete(request) else { endPresentation(); return }
        deleting = true; removalError = nil
        defer { deleting = false; onEvent(.presentationEnded) }
        // Its sessions go first: their worktrees are found through the project.
        do { try await removeSessions(request.projectID) } catch {
            if !retired { removalError = error.localizedDescription }
            return
        }
        guard !retired, isOwned(), model.editor.canDelete(request) else { return }
        await model.editor.delete(request)
    }

    /// Leaving the screen ends its presentation; an already started write finishes.
    func endPresentation() {
        guard deletionConfirmation != nil else { return }
        deletionConfirmation = nil; removalError = nil
        onEvent(.presentationEnded)
    }

    func retire() {
        retired = true; deletionConfirmation = nil
        onEvent = { _ in }; canPresent = { false }; isOwned = { false }
        model.retire()
    }
}
