import Foundation
import Testing

private final class SimulatorPreviewFixture: SimulatorPreviewing, @unchecked Sendable {
    enum Result { case success(URL); case failure(Error) }
    var results: [String: Result] = [:]
    var delays: [String: UInt64] = [:]
    var starts: [String] = []
    /// Starts that have returned or thrown: an answer is on its way back to the model.
    var finished = 0
    var stops = 0

    func start(udid: String) async throws -> URL {
        starts.append(udid)
        defer { finished += 1 }
        if let nanoseconds = delays[udid] { try await Task.sleep(nanoseconds: nanoseconds) }
        switch results[udid] {
        case .success(let url): return url
        case .failure(let error): throw error
        case nil: throw BackendError.operation("No fixture result for \(udid)")
        }
    }
    func stopAll() async { stops += 1 }
}

/// Polls `state` up to ~2s, since a preview's start runs on a detached `Task`.
@MainActor private func waitFor(_ model: SimulatorPreviewModel, _ matches: (SimulatorPreviewModel.State) -> Bool) async {
    for _ in 0..<200 where !matches(model.state) { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Test func simulatorPreviewShowsStartsThenGoesLive() async {
    let service = SimulatorPreviewFixture()
    let url = URL(string: "http://127.0.0.1:3100")!
    service.results["udid-1"] = .success(url)
    service.delays["udid-1"] = 30_000_000
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-1")
    #expect(model.state == .starting && model.udid == "udid-1")
    await waitFor(model) { if case .live = $0 { true } else { false } }
    #expect(model.state == .live(url))
    #expect(service.starts == ["udid-1"])
}

@MainActor @Test func simulatorPreviewMissingBinaryReportsUnavailable() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-2"] = .failure(BackendError.operation("The simulator preview needs Node.js 20 or later. See Settings → Integrations."))
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-2")
    await waitFor(model) { $0 != .starting }
    #expect(model.state == .unavailable)
}

private let noNode = BackendError.operation("The simulator preview needs Node.js 20 or later. See Settings → Integrations.")

/// Node installed from a terminal while the panel said "not set up": coming back to Craft is
/// enough, with no new Run.
@MainActor @Test func anUnavailablePreviewTriesAgainWhenCraftComesBack() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-node"] = .failure(noNode)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-node")
    await waitFor(model) { $0 == .unavailable }
    let url = URL(string: "http://127.0.0.1:3101")!
    service.results["udid-node"] = .success(url)
    model.applicationBecameActive()
    await waitFor(model) { $0 == .live(url) }
    #expect(model.state == .live(url) && service.starts == ["udid-node", "udid-node"])
}

/// Still missing: the quiet check leaves "not set up" on screen and never flashes a spinner.
@MainActor @Test func aQuietCheckThatStillFindsNothingLeavesThePanelAlone() async throws {
    let service = SimulatorPreviewFixture()
    service.results["udid-quiet"] = .failure(noNode)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-quiet")
    await waitFor(model) { $0 == .unavailable }
    model.applicationBecameActive()
    for _ in 0..<60 {
        #expect(model.state == .unavailable)
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.state == .unavailable && service.starts.count == 2)
}

/// A check that gets past "is Node there" is really starting, and the panel says so.
@MainActor @Test func aSlowCheckShowsThatThePreviewIsStarting() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-slow"] = .failure(noNode)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-slow")
    await waitFor(model) { $0 == .unavailable }
    let url = URL(string: "http://127.0.0.1:3102")!
    service.results["udid-slow"] = .success(url)
    service.delays["udid-slow"] = 900_000_000
    model.applicationBecameActive()
    #expect(model.state == .unavailable)
    await waitFor(model) { $0 == .starting }
    #expect(model.state == .starting)
    await waitFor(model) { $0 == .live(url) }
    #expect(model.state == .live(url))
}

/// Two activations in a row, as from two panels or a quick switch away and back, send one check.
@MainActor @Test func comingBackTwiceSendsOneCheck() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-twice"] = .failure(noNode)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-twice")
    await waitFor(model) { $0 == .unavailable }
    service.delays["udid-twice"] = 200_000_000
    model.applicationBecameActive(); model.applicationBecameActive()
    // On signals, not fixed sleeps: the first check answering, then the model taking it.
    await until { service.finished == 2 }
    await waitFor(model) { $0 == .unavailable }
    #expect(service.starts.count == 2 && model.state == .unavailable)
    // The answer reaches the model on its own task; until it has, an activation is still
    // (rightly) covered by the check in flight. Coming back again until one goes out is what a
    // user does, and any check sent while one was out would show as a fourth start.
    await until { model.applicationBecameActive(); return service.starts.count >= 3 }
    await until { service.finished == 3 }
    #expect(service.starts.count == 3, "an answered check does not hold back the next activation")
}

/// Polls `condition` for up to 5s: long enough for a loaded machine, and a failure still ends.
@MainActor private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Coming back asks again only for "not set up"; every other state belongs to the Run behind it.
@MainActor @Test func comingBackLeavesOtherPreviewStatesAlone() async {
    let service = SimulatorPreviewFixture()
    let model = SimulatorPreviewModel(service: service)
    model.applicationBecameActive()
    #expect(model.state == .idle && service.starts.isEmpty)
    service.results["udid-live"] = .success(URL(string: "http://127.0.0.1:3103")!)
    model.show(udid: "udid-live")
    await waitFor(model) { if case .live = $0 { true } else { false } }
    model.applicationBecameActive()
    #expect(service.starts == ["udid-live"])
}

@MainActor @Test func simulatorPreviewOtherErrorReportsFailedMessage() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-3"] = .failure(BackendError.operation("Xcode is busy booting another device."))
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-3")
    await waitFor(model) { $0 != .starting }
    #expect(model.state == .failed("Xcode is busy booting another device."))
}

@MainActor @Test func simulatorPreviewRetiredIgnoresShow() async {
    let service = SimulatorPreviewFixture()
    service.results["udid-4"] = .success(URL(string: "http://127.0.0.1:3100")!)
    let model = SimulatorPreviewModel(service: service)
    model.retire()
    model.show(udid: "udid-4")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.state == .idle && service.starts.isEmpty)
}

@MainActor @Test func simulatorPreviewSecondShowSupersedesSlowFirst() async {
    let service = SimulatorPreviewFixture()
    let firstURL = URL(string: "http://127.0.0.1:3100")!
    let secondURL = URL(string: "http://127.0.0.1:3101")!
    service.results["udid-slow"] = .success(firstURL)
    service.delays["udid-slow"] = 300_000_000
    service.results["udid-fast"] = .success(secondURL)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-slow")
    model.show(udid: "udid-fast")
    await waitFor(model) { if case .live = $0 { true } else { false } }
    #expect(model.state == .live(secondURL) && model.udid == "udid-fast")
}

@Test func simulatorPreviewLoopbackAcceptsOnlyLocalHTTP() {
    #expect(APISimulatorPreviewService.loopback("http://127.0.0.1:3100") == URL(string: "http://127.0.0.1:3100"))
    #expect(APISimulatorPreviewService.loopback("https://example.com") == nil)
    #expect(APISimulatorPreviewService.loopback("http://10.0.0.2:3100") == nil)
}

@Test func workspaceModeSimulatorRoundTripsThroughPane() {
    #expect(WorkspaceMode(pane: .simulator) == .simulator)
    #expect(WorkspaceMode.simulator.pane == .simulator)
}

@Test func cliAvailabilityLabelsNodeAndServeSim() {
    #expect(CLIAvailability(present: true, version: "v22.1.0", supported: true).label(for: .node) == "Installed · v22.1.0")
    #expect(CLIAvailability(present: true, version: "v18.0.0", supported: false).label(for: .node) == "v18.0.0, needs 20 or later")
    #expect(CLIAvailability(present: true).label(for: .serveSim) == "Installed")
    #expect(CLIAvailability(present: false).label(for: .serveSim) == "Needs Node.js 20 or later")
    #expect(CLIAvailability(present: false, needs: "node").label(for: .serveSim) == "Needs Node.js 20 or later")
    #expect(CLIAvailability(present: false, needs: "npx").label(for: .serveSim) == "Needs npx, which comes with npm")
    #expect(CLIAvailability(present: true, source: "npx").label(for: .serveSim) == "Fetched automatically on first use")
}

@Test func nodeNamesItsInstallerAndOffersHomebrewOnlyWhereItFits() {
    let brew = CLIAvailability(present: true, version: "v22.1.0", supported: true, source: "Homebrew")
    #expect(brew.label(for: .node) == "Installed · v22.1.0 · Homebrew")
    #expect(CLIAvailability(present: true, version: "v22.1.0", supported: true, source: "installer").label(for: .node)
            == "Installed · v22.1.0 · Node.js installer")
    #expect(CLIAvailability(present: true, version: "v22.1.0", supported: true, source: "other").label(for: .node) == "Installed · v22.1.0")
    #expect(CLIAvailability(present: true, version: "v18.0.0", supported: false, source: "nvm").label(for: .node)
            == "v18.0.0 · nvm, needs 20 or later")

    let missing = CLIAvailability(present: false)
    #expect(missing.installCommand(for: .node, homebrew: true) == "brew install node")
    #expect(missing.installCommand(for: .node, homebrew: false) == nil, "no Homebrew: the guide covers it")
    #expect(CLIAvailability(present: true, version: "v18.0.0", supported: false, source: "Homebrew")
        .installCommand(for: .node, homebrew: true) == "brew upgrade node")
    #expect(CLIAvailability(present: true, version: "v18.0.0", supported: false, source: "nvm")
        .installCommand(for: .node, homebrew: true) == nil, "a version manager's Node is updated in that manager")
    #expect(brew.installCommand(for: .node, homebrew: true) == nil, "nothing to do for a usable Node")
    #expect(CLIAvailability(present: false).installCommand(for: .ghWebhook, homebrew: false) == "gh extension install cli/gh-webhook")
    #expect(CLIAvailability(present: false).installCommand(for: .serveSim, homebrew: true) == nil)
}

@Test func nodeWithAnUnreadVersionWarnsInsteadOfPassing() {
    let unknown = CLIAvailability(present: true)
    #expect(unknown.label(for: .node) == "Installed · version unknown")
    #expect(unknown.outdated(for: .node))
    #expect(!CLIAvailability(present: true, version: "v22.1.0", supported: true).outdated(for: .node))
    #expect(CLIAvailability(present: true, version: "v18.0.0", supported: false).outdated(for: .node))
    // Only Node has a version requirement: other tools never read as outdated.
    #expect(!CLIAvailability(present: true).outdated(for: .serveSim) && !CLIAvailability(present: true).outdated(for: .gh))
}

@Test func managedCLIRequiredExcludesSimulatorPreviewTools() {
    #expect(!ManagedCLI.required.contains(.node))
    #expect(!ManagedCLI.required.contains(.serveSim))
    #expect(!ManagedCLI.required.contains(.ghWebhook) && ManagedCLI.webhooks == [.ghWebhook])
    #expect(ManagedCLI.simulatorPreview.contains(.node) && ManagedCLI.simulatorPreview.contains(.serveSim))
}

@MainActor @Test func simulatorPreviewRunAgainWhileLiveRechecksWithoutBlanking() async {
    let service = SimulatorPreviewFixture()
    let first = URL(string: "http://127.0.0.1:3100")!, restarted = URL(string: "http://127.0.0.1:3101")!
    service.results["udid-9"] = .success(first)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-9")
    await waitFor(model) { $0 == .live(first) }
    // The helper died and came back on another port: a second Run asks again, keeping the page up meanwhile.
    service.results["udid-9"] = .success(restarted)
    service.delays["udid-9"] = 30_000_000
    model.show(udid: "udid-9")
    #expect(model.state == .live(first))
    await waitFor(model) { $0 == .live(restarted) }
    #expect(model.state == .live(restarted) && service.starts == ["udid-9", "udid-9"])
}

@MainActor @Test func simulatorPreviewPageFailureOffersRetry() async {
    let service = SimulatorPreviewFixture()
    let url = URL(string: "http://127.0.0.1:3100")!
    service.results["udid-10"] = .success(url)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-10")
    await waitFor(model) { $0 == .live(url) }
    model.pageFailed("Could not connect to the server.")
    #expect(model.state == .failed("Could not connect to the server."))
    model.retry()
    await waitFor(model) { $0 == .live(url) }
    #expect(model.state == .live(url))
}

@MainActor @Test func simulatorPreviewPageIsOneWebViewUntilRetired() {
    let model = SimulatorPreviewModel(service: SimulatorPreviewFixture())
    let page = model.webView
    #expect(page.accessibilityIdentifier() == "simulator-preview-webview")
    #expect(model.webView === page)
    model.retire()
    #expect(model.webView !== page)
}

// A panel that left live must load its page again when live comes back, even at the same address:
// after the backend reports a failure, a new helper can take the dead one's port. Two fragments of one
// address stand in for the two helpers' pages, which also keeps the test off the network.
@MainActor @Test func simulatorPageLoadsAgainAfterTheBackendFailsAtTheSameAddress() async {
    let service = SimulatorPreviewFixture()
    let first = URL(string: "about:blank#first")!, second = URL(string: "about:blank#second")!
    service.results["udid-port"] = .success(first)
    let model = SimulatorPreviewModel(service: service)
    model.active = true
    model.show(udid: "udid-port")
    await waitFor(model) { $0 == .live(first) }
    #expect(model.state == .live(first))
    // Made by its first use, and loaded with the live stream.
    let page = model.webView
    #expect(page.url == first)
    service.results["udid-port"] = .failure(BackendError.operation("The device shut down."))
    model.retry()
    await waitFor(model) { if case .failed = $0 { true } else { false } }
    #expect(model.state == .failed("The device shut down."))
    service.results["udid-port"] = .success(second)
    model.retry()
    await waitFor(model) { $0 == .live(second) }
    #expect(model.state == .live(second))
    // Loaded by the state, in the same web view.
    #expect(model.webView === page && page.url == second)
    model.retire()
}

// The stream plays only while its session is on screen: a hidden session's page is unloaded, since
// its helper would go on sending frames nobody sees, and shown again the same web view loads it again.
@MainActor @Test func simulatorPageStreamsOnlyWhileItsSessionIsOnScreen() async {
    let service = SimulatorPreviewFixture()
    let stream = URL(string: "about:blank#stream")!
    service.results["udid-shown"] = .success(stream)
    let model = SimulatorPreviewModel(service: service)
    model.show(udid: "udid-shown")
    await waitFor(model) { $0 == .live(stream) }
    // Made while its session is hidden, the page loads nothing.
    let page = model.webView
    #expect(page.url == nil)
    model.active = true
    #expect(page.url == stream)
    model.active = false
    #expect(page.url != stream)
    model.active = true
    #expect(model.webView === page && page.url == stream)
    model.retire()
}
