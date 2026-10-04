import Foundation
import Testing

@MainActor private final class NewSessionRuntimeFixture: NewSessionCoordinating {
    var composers: [String] = []
    var newProjects = 0
    func newSessionComposer(for projectID: String) -> ProjectComposerModel? { composers.append(projectID); return nil }
    func newSessionNewProject() { newProjects += 1 }
}

@MainActor private func root() -> AppCoordinator { AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil })) }
private let local = Project(id: "p", name: "P", repo: "", color: nil, workspace: "/tmp")

@MainActor @Test func newTaskAsksForNewProjectOnlyWhileItIsOnScreen() {
    let root = root(), runtime = NewSessionRuntimeFixture()
    let model = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    #expect(root.newSession === model)
    root.navigate(to: .overview)
    model.newProject()
    #expect(runtime.newProjects == 0, "New Task is not on screen")
    root.navigate(to: .newSession)
    model.newProject()
    #expect(runtime.newProjects == 1)
    model.update(projects: [local])
    #expect(runtime.composers == ["p"], "The picked project's composer is asked for")
}

@MainActor @Test func aReplacedNewTaskIsRetiredForGood() {
    let root = root(), runtime = NewSessionRuntimeFixture()
    let first = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    let second = root.makeNewSession(factory: NativeNewSessionFeatureFactory(), runtime: runtime)
    #expect(first.retired && !second.retired && root.newSession === second)
    root.navigate(to: .newSession)
    first.newProject(); first.update(projects: [local])
    #expect(runtime.newProjects == 0 && runtime.composers.isEmpty, "A retired New Task asks for nothing")
}
