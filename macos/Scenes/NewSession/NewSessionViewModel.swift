import Foundation
import Observation

/// New Task, at the top of the sidebar: a project's Start, for whichever project is picked here.
/// It shows that project's own composer rather than one of its own, so a link, a draft or a branch
/// picked on either page is the same one, and a session it makes reaches the app as Start's do.
@MainActor @Observable final class NewSessionViewModel {
    /// What the page asks its coordinator to do.
    enum Action: Equatable { case newProject }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    /// The projects a session can start in: those with a folder.
    private(set) var projects: [Project] = []
    private(set) var projectID: String?
    /// The picked project's Start composer; nil until the backend is there to build it.
    private(set) var composer: ProjectComposerModel?
    private(set) var retired = false
    /// The project's composer, built when first asked for.
    @ObservationIgnored var composerFor: (String) -> ProjectComposerModel? = { _ in nil }
    /// The project picker's New Project.
    func newProject() { if !retired { onAction(.newProject) } }

    private static let projectKey = "newSessionProject"

    var project: Project? { projects.first { $0.id == projectID } }

    /// The projects changed, or the backend came: the pick stays when it can, and its composer is
    /// asked for again, as a project's model is rebuilt on reconnect.
    func update(projects: [Project]) {
        guard !retired else { return }
        self.projects = projects.filter { !$0.workspace.isEmpty }
        let saved = UserDefaults.standard.string(forKey: Self.projectKey)
        let next = [projectID, saved].compactMap { $0 }.first { id in self.projects.contains { $0.id == id } }
            ?? self.projects.first?.id
        show(next)
    }

    func choose(_ id: String) {
        guard !retired, projects.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: Self.projectKey)
        show(id)
    }

    /// Opened to start something: in `projectID` when one is given, with what Start is to hold.
    func start(in projectID: String?, text: String? = nil, jiraKey: String? = nil, agent: SessionAgent? = nil) {
        guard !retired else { return }
        if let projectID { choose(projectID) }
        composer?.prepare(text: text, jiraKey: jiraKey, agent: agent)
    }

    func retire() {
        retired = true; composer = nil; onAction = { _ in }; composerFor = { _ in nil }
    }

    private func show(_ id: String?) {
        projectID = id
        let next = id.flatMap(composerFor)
        if next !== composer { composer = next }
    }
}
