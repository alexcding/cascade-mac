import Foundation
import Observation

@MainActor @Observable final class SettingsViewModel {
    enum Action: Equatable {
        case saved([String: String]), cli(CLISettingsViewModel.Action)
        case clearBrowsingData(BrowsingDataScope)
    }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in } {
        didSet {
            let callback = onAction
            clis.onAction = { callback(.cli($0)) }
        }
    }
    private(set) var retired = false
    var section = SettingsSection.general {
        didSet { if oldValue != section { browsingDataNotice = nil; refreshCurrentSection() } }
    }
    private(set) var active = false {
        didSet {
            guard oldValue != active else { return }
            if active { refresh() } else { cancelRead(); browsingDataNotice = nil }
            refreshCurrentSection()
        }
    }
    let clis: CLISettingsViewModel
    let diagnostics: DiagnosticsViewModel
    let loginItem: LoginItemViewModel
    let microphone: MicrophoneAccessViewModel
    let fonts: FontSettingsViewModel
    let resources: ResourceUsageViewModel
    let adBlock: BrowserSettingsViewModel
    var draft = AppConfigDraft() {
        didSet { if oldValue != draft { revision += 1; saved = false } }
    }
    private(set) var loaded = false
    private(set) var saving = false
    private(set) var loading = false
    private(set) var saved = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    var error: String? { saveError ?? loadError }
    private(set) var sounds: [ReviewSound] = []
    /// The scope a clear is in flight for, and the confirmation shown once it lands.
    private(set) var clearingBrowsingData: BrowsingDataScope?
    private(set) var browsingDataNotice: String?
    private var baseline = AppConfigDraft()
    @ObservationIgnored private var service: (any SettingsService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var connection = UUID()
    @ObservationIgnored private var readGeneration = UUID()

    init(clis: CLISettingsViewModel, diagnostics: DiagnosticsViewModel, loginItem: LoginItemViewModel, fonts: FontSettingsViewModel,
         resources: ResourceUsageViewModel, adBlock: BrowserSettingsViewModel, microphone: MicrophoneAccessViewModel) {
        self.clis = clis; self.diagnostics = diagnostics; self.loginItem = loginItem; self.microphone = microphone
        self.fonts = fonts
        self.resources = resources; self.adBlock = adBlock
    }
    var dirty: Bool { draft != baseline }
    func clearBrowsingData(_ scope: BrowsingDataScope) {
        guard !retired, clearingBrowsingData == nil else { return }
        clearingBrowsingData = scope; browsingDataNotice = nil
        onAction(.clearBrowsingData(scope))
    }
    /// The coordinator reports the outcome; a stale report for a scope no longer in flight is
    /// ignored. A clear that lands after the user left keeps no notice for the next visit.
    func browsingDataCleared(_ scope: BrowsingDataScope) {
        guard !retired, clearingBrowsingData == scope else { return }
        clearingBrowsingData = nil
        if active { browsingDataNotice = scope.clearedNotice }
    }
    /// The clear never ran (Settings lost presentation first): re-enable the buttons, no notice.
    func browsingDataClearCancelled(_ scope: BrowsingDataScope) {
        guard !retired, clearingBrowsingData == scope else { return }
        clearingBrowsingData = nil
    }
    func setActive(_ value: Bool) { if !retired { active = value } }
    func refreshCurrentSection() {
        guard !retired else { return }
        // System carries the database inspector and the resource readout, which go live together;
        // the login item sits under General with the other startup and behaviour preferences.
        let system = active && section == .system
        diagnostics.setVisible(system)
        resources.setVisible(system)
        let general = active && section == .general
        loginItem.setActive(general)
        if general { loginItem.refresh() } else { _ = loginItem.cancelRead() }
        // Microphone access is granted or revoked in System Settings; re-read it each time General shows.
        microphone.setActive(general)
        if general { microphone.refresh() }
        // Both tabs show a family picker, so the installed-font catalogue is read for either.
        if active && (section == .editor || section == .terminal) { fonts.refresh() } else { _ = fonts.cancelRead() }
        // The app may have been installed or removed since the last look.
        if active && section == .browser { adBlock.refresh() }
        if active && section == .clis { clis.refresh() } else { clis.cancelReads() }
    }
    func applicationActiveChanged(_ value: Bool) {
        guard !retired else { return }
        resources.setForeground(value)
        if value && active && section == .general { loginItem.refresh(); microphone.refresh() }
        if value && active && section == .browser { adBlock.refresh() }
        // A tool installed from a terminal shows up on return, without pressing Refresh.
        if value && active && section == .clis { clis.refresh() }
    }
    var canSave: Bool { !retired && loaded && dirty && !saving && service != nil && draft.validationError == nil }
    func connect(_ service: any SettingsService) {
        guard !retired else { return }
        disconnect(); self.service = service
    }
    func refresh() {
        guard !retired, task == nil, !saving, let service else { return }
        loading = true
        let requestRevision = revision
        let requestConnection = connection
        let requestRead = readGeneration
        task = Task {
            defer { if readGeneration == requestRead { task = nil; loading = false } }
            do {
                async let soundRequest = try? service.sounds()
                let values = try await service.config()
                try Task.checkCancellation()
                guard connection == requestConnection, readGeneration == requestRead else { return }
                if revision == requestRevision && !dirty {
                    baseline = AppConfigDraft(values); draft = baseline
                }
                loaded = true; loadError = nil
                let sounds = await soundRequest
                try Task.checkCancellation()
                guard connection == requestConnection, readGeneration == requestRead else { return }
                if let sounds { self.sounds = sounds }
            } catch {
                if !Task.isCancelled && connection == requestConnection && readGeneration == requestRead { loadError = error.localizedDescription }
            }
        }
    }
    func save() async {
        guard !retired, loaded, !saving, let service else { return }
        if let error = draft.validationError { saveError = error; return }
        let sent = AppConfigDraft(draft.values)
        let patch = sent.values.filter { baseline.values[$0.key] != $0.value }
        guard !patch.isEmpty else { return }
        let requestConnection = connection
        cancelRead()
        revision += 1; saving = true; saveError = nil; saved = false
        defer { saving = false }
        do {
            try await service.save(patch)
            guard connection == requestConnection else { return }
            baseline = sent
            // Preserve any newer edit made while the request was in flight.
            if draft.values == sent.values { draft = sent }
            saved = true
            onAction(.saved(patch))
        } catch { if connection == requestConnection { saveError = error.localizedDescription } }
    }
    func revert() { guard !retired, !saving else { return }; draft = baseline; saved = false; saveError = nil; loadError = nil }
    private func disconnect() {
        connection = UUID(); cancelRead(); service = nil
    }
    private func cancelRead() { readGeneration = UUID(); task?.cancel(); task = nil; loading = false }
    func retire() { active = false; retired = true; onAction = { _ in }; clis.retire(); loginItem.retire(); microphone.retire(); adBlock.retire(); disconnect() }
    func stop() async {
        let read = task; active = false; disconnect(); diagnostics.stop()
        resources.stop()
        let cliReads = clis.disconnect()
        microphone.setActive(false)
        let loginMutation = loginItem.cancelRead(), fontRead = fonts.cancelRead(), microphoneRead = microphone.cancelRead()
        await loginMutation?.value
        await fontRead?.value
        await microphoneRead?.value
        await read?.value
        for task in cliReads { await task.value }
    }
}
