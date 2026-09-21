import Foundation
import Observation
import Testing

@MainActor @Observable private final class TrayRuntimeFixture: TrayCoordinating {
    var state = TrayState(canNavigate: true)
    var refreshes = 0
    var acknowledged: [TrayPR] = []
    var opened: [OpenPageRequest] = []
    var usageOpens = 0
    var failsOpen = false
    func trayState() -> TrayState { state }
    func refreshTray() { refreshes += 1 }
    func acknowledgeTrayReview(_ review: TrayPR) {
        acknowledged.append(review)
        state.acknowledging.insert(review.id)
    }
    /// While set, an open waits here until `release()`, the way a slow backend would hold it.
    var holdsOpens = false
    private var held: [CheckedContinuation<Void, Never>] = []
    func release() { held.forEach { $0.resume() }; held = [] }
    func openTrayReview(_ request: OpenPageRequest) async throws {
        if holdsOpens { await withCheckedContinuation { held.append($0) } }
        try Task.checkCancellation()
        if failsOpen { throw BackendError.operation("offline") }
        opened.append(request)
    }
    func openTrayUsage() { usageOpens += 1 }
}

@MainActor private final class TrayFactoryFixture: TrayFeatureFactory {
    var models: [TrayViewModel] = []
    func tray(service: any TrayServing, shell: ShellStore) -> TrayViewModel {
        let model = TrayViewModel(service: service, shell: shell)
        models.append(model); return model
    }
}

@MainActor private final class TrayWindowFixture {
    var events: [String] = []
    var presentation: TrayPresentation {
        .init(openWindow: { self.events.append("window") }, dismiss: { self.events.append("dismiss") },
              quit: { self.events.append("quit") })
    }
}

/// Lets the coordinator's open task run to completion.
@MainActor private func settle() async { for _ in 0..<20 { await Task.yield() } }

@MainActor private func trayShell() -> ShellStore {
    ShellStore(preferences: UserDefaults(suiteName: "tray-model-\(UUID().uuidString)")!)
}

private func trayReview(_ number: Int, url: String? = nil, category: String = "review") -> TrayPR {
    TrayPR(url: url ?? "https://example.test/pr/\(number)", repo: "fixture/repo", number: number,
           title: "Review \(number)", state: "OPEN", category: category, awaitingMyReview: true,
           reviewPending: true, projectName: nil, ci: nil)
}

@MainActor @Test func trayCoordinatorOwnsActivationAndRejectsHiddenOrUnownedActions() {
    let runtime = TrayRuntimeFixture(), window = TrayWindowFixture()
    let model = TrayViewModel(service: runtime, shell: trayShell())
    let coordinator = TrayCoordinator(model: model, runtime: runtime, presentation: window.presentation)
    model.refresh()
    #expect(runtime.refreshes == 0)
    coordinator.setActive(true); coordinator.setActive(true)
    #expect(runtime.refreshes == 1 && model.active)
    model.refresh(); #expect(runtime.refreshes == 2)
    coordinator.isOwned = { false }
    model.refresh()
    #expect(runtime.refreshes == 2 && window.events.isEmpty)
    coordinator.isOwned = { true }
    coordinator.setActive(false); model.refresh()
    #expect(runtime.refreshes == 2)
}

@MainActor @Test func trayReviewsOpenInACraftTabAndAcknowledgeOnlySuccessfulOpens() async {
    let runtime = TrayRuntimeFixture(), window = TrayWindowFixture()
    let first = trayReview(1), reviewed = trayReview(2, category: "other")
    runtime.state.pendingReviews = [first, reviewed].filter(\.pendingReview)
    let model = TrayViewModel(service: runtime, shell: trayShell())
    let coordinator = TrayCoordinator(model: model, runtime: runtime, presentation: window.presentation)
    coordinator.setActive(true)
    #expect(model.pendingReviews.map(\.number) == [1])
    model.openReview(reviewed); model.openReview(trayReview(99)); await settle()
    #expect(runtime.opened.isEmpty && runtime.acknowledged.isEmpty)
    runtime.failsOpen = true; model.openReview(first); await settle()
    #expect(runtime.acknowledged.isEmpty && window.events.isEmpty && model.active)
    #expect(model.actionError == "Could not open the pull request in Craft.")
    model.refresh(); #expect(model.actionError != nil)
    let current = trayReview(1, url: "https://example.test/pr/current")
    runtime.state.pendingReviews[0] = current
    runtime.failsOpen = false
    model.openReview(first); await settle() // Re-resolve an old row through its identity.
    #expect(runtime.opened.last?.url == current.url && runtime.opened.last?.kind == "github")
    #expect(runtime.acknowledged == [current] && window.events == ["dismiss", "window"] && !model.active && model.actionError == nil)
    coordinator.setActive(true); model.openReview(first); await settle()
    #expect(runtime.opened.count == 1 && runtime.acknowledged.count == 1, "A review being acknowledged cannot open twice")
    runtime.state.acknowledging = []; runtime.state.canNavigate = false
    model.openReview(first); await settle()
    #expect(runtime.opened.count == 1, "A competing presentation blocks the open")
    runtime.state.canNavigate = true; runtime.state.pendingReviews = [trayReview(1, url: "file:///tmp/private")]
    model.openReview(first); await settle()
    #expect(runtime.opened.count == 1)
    runtime.state.pendingReviews = []; model.openReview(first); await settle()
    #expect(runtime.opened.count == 1)
}

@MainActor @Test func trayClickOnAnotherReviewSupersedesASlowOpen() async {
    let runtime = TrayRuntimeFixture(), window = TrayWindowFixture()
    let first = trayReview(1), second = trayReview(2)
    runtime.state.pendingReviews = [first, second]; runtime.holdsOpens = true
    let model = TrayViewModel(service: runtime, shell: trayShell())
    let coordinator = TrayCoordinator(model: model, runtime: runtime, presentation: window.presentation)
    coordinator.setActive(true)
    model.openReview(first); model.openReview(first); await settle()
    model.openReview(second); await settle()
    runtime.release(); await settle()
    #expect(runtime.opened.map(\.url) == [second.url], "The superseded open is cancelled, the repeat click ignored")
    #expect(runtime.acknowledged == [second] && window.events == ["dismiss", "window"] && model.actionError == nil)
}

@MainActor @Test func trayFactoryReplacementRetiresCallbacksAndDoesNotRetainRuntimeOrRoot() {
    let factory = TrayFactoryFixture(), window = TrayWindowFixture(), shell = trayShell()
    var runtime: TrayRuntimeFixture? = TrayRuntimeFixture()
    weak var retainedRuntime = runtime
    var root: AppCoordinator? = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    weak var retainedRoot = root
    let old = root!.makeTray(factory: factory, runtime: runtime!, shell: shell, presentation: window.presentation)
    old.setActive(true)
    let stale = old.model.onAction
    let fresh = root!.makeTray(factory: factory, runtime: runtime!, shell: shell, presentation: window.presentation)
    #expect(factory.models.count == 2 && fresh.model.shell === shell && old.retired && old.model.retired)
    old.setActive(true); old.model.refresh(); stale(.refresh)
    #expect(runtime?.refreshes == 1 && window.events.isEmpty && !old.model.active)
    fresh.setActive(true)
    #expect(runtime?.refreshes == 2)
    runtime = nil
    #expect(retainedRuntime == nil && !fresh.model.available)
    fresh.model.refresh()
    root = nil
    #expect(retainedRoot == nil)
    fresh.handle(.refresh)
    #expect(window.events.isEmpty)
}

@MainActor @Test func trayWindowUsageAndQuitGoThroughThePresentation() {
    let runtime = TrayRuntimeFixture(), window = TrayWindowFixture()
    let model = TrayViewModel(service: runtime, shell: trayShell())
    let coordinator = TrayCoordinator(model: model, runtime: runtime, presentation: window.presentation)
    model.openUsage()
    #expect(runtime.usageOpens == 0, "Nothing opens while the menu is closed")
    coordinator.setActive(true); model.openUsage()
    #expect(runtime.usageOpens == 1 && window.events == ["dismiss", "window"] && !model.active)
    coordinator.setActive(true); model.quit()
    #expect(window.events.last == "quit")
    #expect(TrayMenuController.truncate("a very long pull request title that goes past the limit", limit: 12) == "a very long…")
    #expect(TrayMenuController.truncate("short", limit: 12) == "short")
}

@MainActor @Test func trayUsageChangesPreserveReviewMenuItems() async throws {
    let runtime = TrayRuntimeFixture(), shell = trayShell()
    runtime.state.pendingReviews = [trayReview(1)]
    let model = TrayViewModel(service: runtime, shell: shell)
    let controller = TrayMenuController(model: model, setActive: model.setActive)
    controller.menuWillOpen(controller.menu)
    await settle()
    let original = try #require(controller.menu.items.first { $0.title.hasPrefix("PR #1") })
    shell.setUsageAgent("codex")
    await settle()
    #expect(controller.menu.items.contains { $0 === original })
    runtime.state.pendingReviews = [trayReview(2)]
    await settle()
    #expect(!controller.menu.items.contains { $0 === original })
    let replacement = try #require(controller.menu.items.first { $0.title.hasPrefix("PR #2") })
    shell.setUsageAgent("claude")
    await settle()
    #expect(controller.menu.items.contains { $0 === replacement })
    controller.menuDidClose(controller.menu)
}
