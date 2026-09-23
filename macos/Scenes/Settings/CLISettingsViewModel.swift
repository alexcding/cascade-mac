import Foundation
import Observation

@MainActor @Observable final class CLISettingsViewModel {
    enum Action: Equatable { case copyLogin(ManagedCLI), copyInstall(ManagedCLI), openGuide(ManagedCLI), toggleHook(ManagedCLI), toggleStatusLine, showWelcome }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    private(set) var retired = false
    private(set) var actionError: String?
    private(set) var availability: [String: CLIAvailability] = [:]
    private(set) var hooks: [String: String] = [:]
    private(set) var probing = false
    private(set) var loadingHooks = false
    private(set) var changing: ManagedCLI?
    private(set) var probeError: String?
    private(set) var hookError: String?
    private(set) var message: String?
    @ObservationIgnored private var service: (any CLISettingsService)?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var hookTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readGeneration = UUID()
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private let copy: (String) -> Void
    @ObservationIgnored private let openBrowser: (URL) -> Bool

    init(copy: @escaping (String) -> Void, openBrowser: @escaping (URL) -> Bool) { self.copy = copy; self.openBrowser = openBrowser }
    func connect(_ service: any CLISettingsService) { guard !retired else { return }; _ = disconnect(); self.service = service }
    func label(_ cli: ManagedCLI) -> String { availability[cli.rawValue]?.label(for: cli) ?? (probing ? "Checking…" : "Not checked") }
    func hookLabel(_ cli: ManagedCLI) -> String {
        guard let status = hooks[cli.rawValue] else { return loadingHooks ? "Checking…" : "Not checked" }
        return switch status { case "installed": "Installed"; case "outdated": "Update available"; default: "Not installed" }
    }
    /// An install from before a hook was added still works; installing again is what adds it.
    func hookAction(_ cli: ManagedCLI) -> String {
        switch hooks[cli.rawValue] { case "installed": "Remove hook"; case "outdated": "Update hook"; default: "Install hook" }
    }
    func canChange(_ cli: ManagedCLI) -> Bool {
        !retired && cli.supportsHooks && service != nil && changing == nil && hooks[cli.rawValue] != nil
    }
    func refresh() {
        guard !retired, let service else { return }
        let requestGeneration = readGeneration
        if probeTask == nil {
            probing = true
            probeTask = Task {
                defer { if readGeneration == requestGeneration { probeTask = nil; probing = false } }
                do {
                    let result = try await service.probe()
                    try Task.checkCancellation()
                    guard readGeneration == requestGeneration else { return }
                    availability = result; probeError = nil
                } catch { if !Task.isCancelled && readGeneration == requestGeneration { probeError = error.localizedDescription } }
            }
        }
        if hookTask == nil && changing == nil && !changingStatusLine {
            loadingHooks = true
            hookTask = Task {
                defer { if readGeneration == requestGeneration { hookTask = nil; loadingHooks = false } }
                do {
                    let result = try await service.hooks()
                    try Task.checkCancellation()
                    guard readGeneration == requestGeneration else { return }
                    hooks = result; hookError = nil
                } catch { if !Task.isCancelled && readGeneration == requestGeneration { hookError = error.localizedDescription } }
            }
        }
    }
    private var statusLine: String? { hooks[APICLISettingsService.statusLineKey] }
    var statusLineInstalled: Bool { statusLine == "installed" }
    private(set) var changingStatusLine = false
    var statusLineLabel: String {
        guard let statusLine else { return loadingHooks ? "Checking…" : "Not checked" }
        return statusLine == "installed" ? "Installed" : "Not installed"
    }
    var canChangeStatusLine: Bool { !retired && service != nil && changing == nil && !changingStatusLine && statusLine != nil }
    func requestToggleStatusLine() { if canChangeStatusLine { onAction(.toggleStatusLine) } }
    func toggleStatusLine() async {
        guard canChangeStatusLine, let service else { return }
        let installed = !statusLineInstalled
        let requestGeneration = generation
        changingStatusLine = true; hookError = nil; message = nil
        defer { changingStatusLine = false }
        // A read started before this edit must not replace its returned status.
        hookTask?.cancel(); await hookTask?.value
        guard requestGeneration == generation else { return }
        do {
            let result = try await service.setStatusLine(installed: installed)
            guard requestGeneration == generation else { return }
            hooks = result
            message = "Claude Code status line \(installed ? "installed" : "removed")."
        } catch { if requestGeneration == generation { hookError = error.localizedDescription } }
    }
    func toggleHook(_ cli: ManagedCLI) async {
        guard canChange(cli), let service else { return }
        let installed = hooks[cli.rawValue] != "installed"
        let requestGeneration = generation
        changing = cli; hookError = nil; message = nil
        defer { changing = nil }
        // A read started before this edit must not replace its returned status.
        hookTask?.cancel(); await hookTask?.value
        guard requestGeneration == generation else { return }
        do {
            let result = try await service.setHook(cli, installed: installed)
            guard requestGeneration == generation else { return }
            hooks = result
            message = "\(cli.title) hooks \(installed ? "installed" : "removed")."
        } catch { if requestGeneration == generation { hookError = error.localizedDescription } }
    }
    func copyLogin(_ cli: ManagedCLI) { if !retired { onAction(.copyLogin(cli)) } }
    func copyInstall(_ cli: ManagedCLI) { if !retired { onAction(.copyInstall(cli)) } }
    /// The install line for `cli` as this Mac stands: Node's goes through Homebrew only when the
    /// probe found Homebrew.
    func installCommand(_ cli: ManagedCLI) -> String? {
        guard let state = availability[cli.rawValue] else { return cli.installCommand }
        return state.installCommand(for: cli, homebrew: availability["brew"]?.present == true)
    }
    func openGuide(_ cli: ManagedCLI) { if !retired { onAction(.openGuide(cli)) } }
    /// Presenting is the coordinator's: the welcome is a sheet on the main window, not on Settings.
    func showWelcome() { if !retired { onAction(.showWelcome) } }
    func requestToggleHook(_ cli: ManagedCLI) { if canChange(cli) { onAction(.toggleHook(cli)) } }
    func perform(_ action: Action) {
        guard !retired else { return }
        switch action {
        case .copyLogin(let cli):
            if let command = cli.loginCommand { copy(command); actionError = nil }
        case .copyInstall(let cli):
            if let command = installCommand(cli) { copy(command); actionError = nil }
        case .openGuide(let cli):
            actionError = openBrowser(cli.installationGuide) ? nil : "macOS could not open the installation guide."
        case .toggleHook(let cli):
            guard canChange(cli), mutationTask == nil else { return }
            let started = generation
            mutationTask = Task { await toggleHook(cli); mutationTask = nil; reloadIfReconnected(since: started) }
        case .toggleStatusLine:
            guard canChangeStatusLine, mutationTask == nil else { return }
            let started = generation
            mutationTask = Task { await toggleStatusLine(); mutationTask = nil; reloadIfReconnected(since: started) }
        case .showWelcome: break
        }
    }
    /// A backend that reconnects mid-edit drops the edit's returned status, and the refresh that
    /// came with the reconnect skipped the hooks because the edit was still running.
    private func reloadIfReconnected(since started: UUID) { if started != generation { refresh() } }
    func waitForMutation() async { await mutationTask?.value }
    @discardableResult func cancelReads() -> [Task<Void, Never>] {
        let reads = [probeTask, hookTask].compactMap { $0 }
        readGeneration = UUID(); probeTask?.cancel(); hookTask?.cancel()
        probeTask = nil; hookTask = nil; probing = false; loadingHooks = false
        return reads
    }
    func disconnect() -> [Task<Void, Never>] {
        generation = UUID(); service = nil
        return cancelReads() + [mutationTask].compactMap { $0 }
    }
    func retire() { retired = true; onAction = { _ in }; _ = disconnect() }
    func stop() async {
        for task in disconnect() { await task.value }
    }
}
