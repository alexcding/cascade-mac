import Foundation
import Observation

@MainActor protocol SettingsFeatureFactory { func settings() -> SettingsViewModel }

@MainActor struct NativeSettingsFeatureFactory: SettingsFeatureFactory {
    let desktop: any DesktopActions
    let copy: (String) -> Void
    var loginItem: any LoginItemService = NativeLoginItemService()
    var microphone: any MicrophoneAccessService = NativeMicrophoneAccessService()
    var fontCatalog: any CodeFontCatalog = InstalledCodeFontCatalog()
    /// Nil builds an inert blocker, the way `BrowserPageFactory` leaves pages unattached.
    var adBlocker: BrowserAdBlocker?

    func settings() -> SettingsViewModel {
        SettingsViewModel(clis: CLISettingsViewModel(copy: copy, openBrowser: desktop.openBrowser), diagnostics: DiagnosticsViewModel(),
            loginItem: LoginItemViewModel(service: loginItem), fonts: FontSettingsViewModel(catalog: fontCatalog),
            resources: ResourceUsageViewModel(),
            adBlock: BrowserSettingsViewModel(blocker: adBlocker ?? .inert(), openBrowser: desktop.openBrowser),
            microphone: MicrophoneAccessViewModel(service: microphone))
    }
}

@MainActor protocol SettingsCoordinating: AnyObject {
    func applySettingsSave(_ patch: [String: String]) async
    func activateSettings()
    func clearBrowsingData(_ scope: BrowsingDataScope) async
    func presentWelcome()
}

@MainActor @Observable final class SettingsCoordinator: Coordinatable {
    /// Unused: `SettingsWindowView` builds the window's content, which also needs the logs coordinator.
    var root: Destination = .none
    var path: [Destination] = []
    @ObservationIgnored var action: ((Action) -> Void)?

    let model: SettingsViewModel
    let shell: ShellStore
    private(set) var retired = false
    @ObservationIgnored private weak var runtime: (any SettingsCoordinating)?
    @ObservationIgnored var isOwned: () -> Bool = { true }
    @ObservationIgnored var canPresent: () -> Bool = { true }
    @ObservationIgnored private var completion: Task<Void, Never>?
    init(model: SettingsViewModel, shell: ShellStore = ShellStore(), runtime: any SettingsCoordinating) {
        self.model = model; self.shell = shell; self.runtime = runtime
        model.onAction = { [weak self] in self?.handle($0) }
    }
    func makeDestination(for route: Route) -> Destination { .none }
    func handle(_ action: Action) {
        if case .settings(let action) = action { handle(action) } else { self.action?(action) }
    }
    func handle(_ action: SettingsViewModel.Action) {
        guard !retired, isOwned(), runtime != nil else { return }
        switch action {
        case .cli(let action):
            guard model.active, model.section == .clis, canPresent() else { return }
            if action == .showWelcome { runtime?.presentWelcome() }
        case .clearBrowsingData(let scope):
            guard model.active, model.section == .browser, canPresent() else { model.browsingDataClearCancelled(scope); return }
            let previous = completion
            completion = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, !retired, isOwned() else { return }
                await runtime?.clearBrowsingData(scope)
                model.browsingDataCleared(scope)
            }
        case .saved(let patch):
            let previous = completion
            completion = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, !retired, isOwned() else { return }
                // Saving connections applies even if the user has since left Settings.
                await runtime?.applySettingsSave(patch)
            }
        }
    }
    func setActive(_ value: Bool) {
        guard !retired, isOwned(), model.active != value else { return }
        if value {
            guard let runtime else { return }
            runtime.activateSettings()
        }
        model.setActive(value)
    }
    func waitForCompletion() async { await completion?.value }
    func cancelNavigation() { model.loginItem.cancelSettingsOpen(); model.microphone.cancelSettingsOpen() }
    func retire() {
        retired = true; isOwned = { false }; canPresent = { false }; completion?.cancel(); completion = nil
        runtime = nil; model.retire()
        Task { await model.stop() }
    }
}

extension AppCoordinator {
    @discardableResult func installSettings(_ model: SettingsViewModel, shell: ShellStore = ShellStore(), runtime: any SettingsCoordinating) -> SettingsCoordinator {
        if let existing = settingsCoordinator, existing.model === model { return existing }
        model.loginItem.inheritRegistration(from: settingsCoordinator?.model.loginItem)
        settingsCoordinator?.retire()
        let child = SettingsCoordinator(model: model, shell: shell, runtime: runtime)
        child.isOwned = { [weak self, weak model] in
            guard let self, let model else { return false }
            return settingsCoordinator?.model === model
        }
        child.canPresent = { [weak self] in
            self?.settingsPresented == true && self?.canPresent == true && self?.canOpenExternalRoute() == true
        }
        model.loginItem.canAct = { [weak child] in
            guard let child, !child.retired, child.isOwned() else { return false }
            return child.canPresent()
        }
        model.clis.canAct = { [weak child] in
            guard let child, !child.retired, child.isOwned(), child.model.active, child.model.section == .clis else { return false }
            return child.canPresent()
        }
        settingsCoordinator = child
        child.setActive(settingsPresented)
        return child
    }
    func makeSettings(factory: any SettingsFeatureFactory, shell: ShellStore = ShellStore(), runtime: any SettingsCoordinating) -> SettingsViewModel {
        installSettings(factory.settings(), shell: shell, runtime: runtime).model
    }
}
