import Foundation
import Testing

@MainActor private final class NotificationRuntime: NotificationCoordinating, RootCoordinating {
    var acknowledged: [String] = []
    var pages: [OpenPageRequest] = []
    var pageSucceeds = true
    var pageInApp = true
    var activations = 0
    func acknowledgeNotificationReview(repo: String, number: Int) { acknowledged.append("\(repo)#\(number)") }
    func openNotificationPage(_ request: OpenPageRequest) async throws -> Bool {
        pages.append(request)
        if !pageSucceeds { throw BackendError.operation("offline") }
        return pageInApp
    }
    func rootState() -> RootState { RootState() }
    func activateRootDestination() { activations += 1 }
    func performRootCommand(_ command: ShellCommand) {}
    func reconnect() async {}
    func togglePin(_ id: String) {}
    func closeTab(_ url: String) {}
    func openTerminal() {}
    func openRootBrowser(_ url: URL) {}
}

@MainActor private final class HeldNotificationDelivery: NotificationDelivery {
    var status = NotificationAccess(permission: .notDetermined, soundAllowed: true)
    var readGate: ProjectPageGate?
    var requestGate: ProjectPageGate?
    var deliveryGate: ProjectPageGate?
    var reads = 0, requests = 0, deliveries = 0
    var sounds: [String] = []
    var failDelivery = false
    func access() async -> NotificationAccess {
        reads += 1
        let result = status, gate = readGate; readGate = nil
        try? await gate?.wait()
        return result // Deliberately ignore cancellation to exercise stale completions.
    }
    func requestAuthorization() async throws {
        requests += 1
        let gate = requestGate; requestGate = nil
        try? await gate?.wait()
        status.permission = .authorized
    }
    func deliver(_ notice: NativeNotice) async throws {
        deliveries += 1
        let gate = deliveryGate; deliveryGate = nil
        try? await gate?.wait()
        if failDelivery { throw CocoaError(.fileWriteUnknown) }
    }
    func playReviewSound(_ path: String) throws { sounds.append(path) }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func notificationPermissionAndPreviewRequireCoordinatorOwnershipAndCoalesce() async {
    let model = NotificationStore(), delivery = HeldNotificationDelivery()
    let runtime = NotificationRuntime()
    model.configure(delivery); await model.waitForDelivery()
    model.enable(); model.previewSound("system")
    await model.waitForDelivery()
    #expect(delivery.requests == 0 && delivery.sounds.isEmpty) // Unwired intents do nothing.
    let child = NotificationCoordinator(model: model, runtime: runtime)
    model.enable(); model.previewSound("system")
    #expect(delivery.requests == 0 && delivery.sounds.isEmpty)
    child.canUsePreferences = { true }; child.isOwned = { false }
    model.enable(); model.previewSound("system")
    #expect(delivery.requests == 0 && delivery.sounds.isEmpty)
    child.isOwned = { true }
    model.previewSound("off"); model.previewSound("system")
    #expect(delivery.sounds == ["system"])
    let gate = ProjectPageGate(); delivery.requestGate = gate
    model.enable(); model.enable()
    await gate.waitForStart()
    #expect(model.requesting && delivery.requests == 1)
    model.refreshAuthorization()
    #expect(delivery.reads == 1)
    await gate.finish(); await model.waitForDelivery()
    #expect(!model.requesting && model.permission == .authorized)
    let callback = model.onAction
    child.retire(); callback(.enable); callback(.previewSound("system"))
    model.configure(delivery); model.showToast(NativeNotice(kind: .activity, title: "retired", body: ""))
    #expect(delivery.requests == 1 && delivery.sounds.count == 1 && model.toast == nil && !model.accepts(delivery))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func notificationClicksOpenCurrentRowsInTabsAndAcknowledgeOnlySuccessfulReviewOpens() async {
    let model = NotificationStore(), runtime = NotificationRuntime()
    let child = NotificationCoordinator(model: model, runtime: runtime)
    var activities = 0, windows = 0
    child.openActivity = { activities += 1 }; child.showWindow = { windows += 1 }
    let first = NativeNotice(id: "one", kind: .review, title: "Review", body: "", url: "https://github.com/a/b/pull/1", repo: "a/b", number: 1)
    var current = first; current.url = "https://github.com/a/b/pull/2"
    model.showToast(current)
    runtime.pageSucceeds = false
    model.open(first); await child.waitForOpen()
    #expect(runtime.pages.map(\.url) == [current.url!] && runtime.acknowledged.isEmpty && windows == 1)
    #expect(runtime.pages.first?.kind == "github" && runtime.pages.first?.repo == "a/b" && runtime.pages.first?.title == "Review")
    #expect(model.toast == current && model.actionError != nil)
    runtime.pageSucceeds = true
    model.open(first); await child.waitForOpen()
    #expect(runtime.acknowledged == ["a/b#1"] && model.toast == nil && model.actionError == nil && windows == 2)
    model.open(first); await child.waitForOpen() // An old view callback no longer owns a current row.
    #expect(runtime.pages.count == 2)
    var unsafe = first; unsafe.url = "file:///tmp/private"
    model.openDelivered(unsafe); await child.waitForOpen()
    #expect(model.actionError != nil && runtime.pages.count == 2 && activities == 0)
    let web = NativeNotice(kind: .activity, title: "Page", body: "", url: "https://notgithub.com/page")
    model.openDelivered(web); await child.waitForOpen()
    #expect(runtime.pages.last?.kind == "web" && runtime.acknowledged.count == 1 && windows == 3)
    var upper = web; upper.url = "https://GitHub.com/a/b"
    runtime.pageInApp = false // Opened in the browser: Craft's window stays behind it.
    model.openDelivered(upper); await child.waitForOpen()
    #expect(runtime.pages.last?.kind == "github" && model.actionError == nil && windows == 3)
    runtime.pageInApp = true
    let newer = NativeNotice(kind: .activity, title: "New", body: "")
    model.showToast(newer)
    model.openDelivered(first); await child.waitForOpen() // OS clicks remain valid after bounded history eviction.
    #expect(runtime.acknowledged.count == 2 && model.toast == newer)
    model.open(newer)
    #expect(activities == 1 && windows == 5 && model.toast == nil)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func notificationOldStopCannotClearNewPermissionRequest() async {
    let model = NotificationStore(), old = HeldNotificationDelivery(), next = HeldNotificationDelivery()
    model.configure(old); await model.waitForDelivery()
    let oldRequest = ProjectPageGate(); old.requestGate = oldRequest
    model.requestAuthorization(); await oldRequest.waitForStart()
    let stop = Task { await model.stop() }
    while model.requesting { await Task.yield() }
    model.configure(next); await model.waitForDelivery()
    let request = ProjectPageGate(); next.requestGate = request
    model.requestAuthorization(); await request.waitForStart()
    await oldRequest.finish(); await stop.value
    #expect(model.permission == .notDetermined && model.requesting && model.accepts(next) && !model.accepts(old))
    let waiter = Task { await model.waitForDelivery(); return true }
    await request.finish(); _ = await waiter.value
    #expect(!model.requesting && model.permission == .authorized)
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func notificationReplacementSuppressesLateDeliveryErrorsAndChimes(fail: Bool) async {
    let model = NotificationStore(), old = HeldNotificationDelivery(), next = HeldNotificationDelivery()
    old.status.permission = .authorized; old.failDelivery = fail
    model.configure(old); await model.waitForDelivery()
    let gate = ProjectPageGate(); old.deliveryGate = gate
    model.receiveReviews([], sound: "system")
    let review = TrayPR(url: "https://example.test/pr/1", repo: "a/b", number: 1, title: "Review", state: "OPEN", category: "review",
        awaitingMyReview: true, reviewPending: true, requestedAt: "first", projectName: nil, ci: nil)
    model.receiveReviews([review], sound: "system"); await gate.waitForStart()
    let drain = Task { await model.waitForDelivery() }; await Task.yield()
    model.configure(next); await model.waitForDelivery()
    await gate.finish(); await drain.value
    #expect(model.permission == .notDetermined && model.error == nil && old.sounds.isEmpty)
    model.receiveReviews([review], sound: "system"); await model.waitForDelivery()
    #expect(next.deliveries == 0) // Replacing delivery does not reseed announcement history.
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func notificationActivityNavigationUsesRootQueueAndRetiredCallbacksCannotNavigate() async throws {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = NotificationRuntime(), model = NativeNotificationFeatureFactory().notifications()
    root.rootRuntime = runtime
    let settingsRuntime = SettingsRuntimeFixture()
    let settingsChild = root.installSettings(settingsFixtureModel(), runtime: settingsRuntime)
    let child = root.installNotifications(model, runtime: runtime)
    var windows = 0; child.showWindow = { windows += 1 }
    var opens = 0; root.presentSettingsWindow = { opens += 1 }
    let notice = NativeNotice(kind: .activity, title: "Sync failed", body: "Offline")
    model.openDelivered(notice)
    #expect(windows == 1 && opens == 1 && root.settingsCoordinator?.model.section == .activity)
    let callback = model.onAction
    let replacement = NotificationStore()
    root.installNotifications(replacement, runtime: runtime)
    callback(.openDelivered(notice))
    #expect(model.retired && child.retired && windows == 1 && opens == 1)
    root.notificationCoordinator?.retire(); settingsChild.retire()
}

@MainActor @Test func notificationCallbacksCannotActAfterRuntimeRelease() async {
    let model = NotificationStore(), delivery = RecordingNotifications()
    var runtime: NotificationRuntime? = NotificationRuntime()
    weak var released = runtime
    let child = NotificationCoordinator(model: model, runtime: runtime!)
    child.canUsePreferences = { true }
    model.configure(delivery); await model.waitForDelivery()
    runtime = nil
    model.previewSound("system")
    model.openDelivered(NativeNotice(kind: .activity, title: "Click", body: "", url: "https://example.test"))
    await child.waitForOpen()
    #expect(released == nil && delivery.sounds.isEmpty)
    child.retire()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func notificationLatePermissionReadCannotOverwriteNewDeliveryState() async {
    let model = NotificationStore(), old = HeldNotificationDelivery(), next = HeldNotificationDelivery()
    let gate = ProjectPageGate(); old.readGate = gate
    model.configure(old); model.refreshAuthorization()
    await gate.waitForStart()
    #expect(old.reads == 1)
    let drain = Task { await model.stop() }
    // A second queued read proves stop invalidated the first read before replacement.
    while old.reads == 1 { await Task.yield(); model.refreshAuthorization() }
    next.status.permission = .denied
    model.configure(next); await model.waitForDelivery()
    await gate.finish(); await drain.value
    #expect(model.permission == .denied && !model.canEnable && model.accepts(next))
    await model.stop()
}

@MainActor @Test func notificationPreferencesFollowSettingsSectionAndRootPresentation() async {
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let runtime = NotificationRuntime(), model = NotificationStore(), delivery = RecordingNotifications()
    let settingsRuntime = SettingsRuntimeFixture()
    let settings = settingsFixtureModel()
    root.installSettings(settings, runtime: settingsRuntime)
    let child = root.installNotifications(model, runtime: runtime)
    model.configure(delivery); await model.waitForDelivery()
    model.previewSound("system")
    #expect(delivery.sounds.isEmpty)
    root.setSettingsPresented(true)
    model.previewSound("system")
    #expect(delivery.sounds.count == 1)
    settings.section = .system
    model.previewSound("system")
    #expect(delivery.sounds.count == 1)
    settings.section = .general
    root.presentNewProject(service: ProjectPageService()) { _ in }
    model.previewSound("system")
    #expect(delivery.sounds.count == 1)
    child.retire(); root.settingsCoordinator?.retire()
}

@MainActor @Test func notificationForegroundPolicyRechecksFocusAndRetirement() {
    let model = NotificationStore()
    let activity = NativeNotice(kind: .activity, title: "Activity", body: "")
    #expect(model.shouldPresentBanner(for: activity) && model.toast == nil)
    model.isMainWindowFocused = { true }
    #expect(!model.shouldPresentBanner(for: activity) && model.toast == activity)
    #expect(model.shouldPresentBanner(for: NativeNotice(kind: .review, title: "Review", body: "")))
    model.retire()
    #expect(!model.shouldPresentBanner(for: activity) && model.toast == nil)
}
