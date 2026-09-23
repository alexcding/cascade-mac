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
    /// Lifecycle events the parent needs: a save, a deletion, or the end of a presentation.
    enum Event { case saved(Project, ProjectSaveSource), deleted(String), presentationEnded }
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: ProjectPageViewModel
    private(set) var deletionConfirmation: ProjectEditorViewModel.DeletionRequest?
    private(set) var deleting = false
    private(set) var retired = false
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored var isOwned: () -> Bool = { true }
    var isPresenting: Bool { deletionConfirmation != nil || deleting }
    init(model: ProjectPageViewModel) {
        self.model = model
        root = .project(model)
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    /// Sections are not pushed; the page switches in place.
    func navigate(to route: Route) {
        if case .projectSection(let section) = route { handle(.selectSection(section)) }
    }
    func handle(_ action: Action) {
        if case .project(let action) = action { handle(action) } else { self.action?(action) }
    }

    func handle(_ action: ProjectPageViewModel.Action) {
        guard !retired, isOwned() else { return }
        switch action {
        case .selectSection(let section): model.setSection(section)
        case .saved(let project, let source): onEvent(.saved(project, source))
        case .deleted(let id):
            guard id == model.project.id else { return }
            deletionConfirmation = nil
            onEvent(.deleted(id))
        case .requestDeletion(let request):
            guard !isPresenting, canPresent(), model.editor.canDelete(request) else { return }
            model.cancelActions()
            deletionConfirmation = request
        case .pullRequest(let request):
            guard !isPresenting, canPresent(), model.section == .prs else { return }
            model.openPage(request)
        case .jiraTicket(.open(let request)):
            guard !isPresenting, canPresent(), model.section == .tickets else { return }
            model.tickets?.navigation.open(request)
        case .boardTicket(.open(let request)):
            guard !isPresenting, canPresent(), model.section == .board else { return }
            model.board?.navigation.open(request)
        }
    }

    func cancelDeletion(id: UUID) {
        guard deletionConfirmation?.id == id, !deleting else { return }
        endPresentation()
    }

    func confirmDeletion(id: UUID) async {
        guard !retired, !deleting, let request = deletionConfirmation, request.id == id else { return }
        guard isOwned(), model.editor.canDelete(request) else { endPresentation(); return }
        deleting = true
        defer { deleting = false; onEvent(.presentationEnded) }
        await model.editor.delete(request)
    }

    /// Leaving the screen ends its presentation; an already started write finishes.
    func endPresentation() {
        model.cancelActions()
        guard deletionConfirmation != nil else { return }
        deletionConfirmation = nil
        onEvent(.presentationEnded)
    }

    func retire() {
        retired = true; deletionConfirmation = nil
        onEvent = { _ in }; canPresent = { false }; isOwned = { false }
        model.retire()
    }

    @discardableResult func navigate(to deepLink: DeepLink) -> Bool {
        guard !retired, isOwned(), deepLink.routes.count == 1, case .projectSection(let section) = deepLink.first else { return false }
        handle(.selectSection(section))
        return true
    }
}
