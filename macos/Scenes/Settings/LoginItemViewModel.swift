import Foundation
import Observation

@MainActor @Observable final class LoginItemViewModel {
    enum Action: Equatable { case setEnabled(Bool), openSystemSettings }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    private(set) var retired = false
    private(set) var active = false {
        didSet {
            guard oldValue != active else { return }
            if active { refresh() }
            else { _ = cancelRead(); cancelSettingsOpen() }
        }
    }
    private(set) var state: LoginItemState?
    private(set) var loading = false
    private(set) var changing = false
    private(set) var openingSettings = false
    private(set) var error: String?
    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var mutation: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var settingsOpen: Task<Void, Never>?
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var mutationFailure: String?

    init(service: any LoginItemService) { self.service = service }
    var registered: Bool { state?.registered == true }
    var needsApproval: Bool { state?.status == .requiresApproval }
    var canToggle: Bool {
        guard !retired, active, let state, !loading, !changing else { return false }
        return state.registered || (state.registrationUnavailableReason == nil && state.status == .notRegistered)
    }
    var canOpenSystemSettings: Bool { !retired && active && needsApproval && !changing && !openingSettings }
    var statusText: String {
        guard let state else { return "Checking login-item status…" }
        switch state.status {
        case .notRegistered: return "Off"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Registered; approval required in System Settings."
        case .notFound: return "macOS could not find this login item. Reinstall the packaged app."
        case .unknown: return "macOS returned an unknown login-item status."
        }
    }
    func refresh() {
        guard !retired, read == nil, !changing else { return }
        loading = true
        let requestRevision = revision
        read = Task {
            let result = await service.state()
            guard !retired, !Task.isCancelled, revision == requestRevision else { return }
            if state?.status != result.status { error = nil }
            state = result; loading = false; read = nil
        }
    }
    func setEnabled(_ enabled: Bool) {
        guard canToggle, enabled != registered else { return }
        onAction(.setEnabled(enabled))
    }
    func openSystemSettings() {
        guard canOpenSystemSettings else { return }
        onAction(.openSystemSettings)
    }
    func perform(_ action: Action) {
        guard !retired, active else { return }
        switch action {
        case .setEnabled(let enabled): changeRegistration(enabled)
        case .openSystemSettings: openSettings()
        }
    }
    private func changeRegistration(_ enabled: Bool) {
        guard canToggle, enabled != registered else { return }
        cancelSettingsOpen()
        revision = UUID(); read?.cancel(); read = nil; loading = false
        changing = true; error = nil; mutationFailure = nil
        mutation = Task {
            defer { changing = false; mutation = nil }
            var failure: String?
            do { try await service.setEnabled(enabled) }
            catch { failure = error.localizedDescription }
            // Even a failed registration can change approval state. Read the OS
            // after both success and failure rather than optimistically flipping.
            let result = await service.state()
            mutationFailure = failure
            guard !retired else { return }
            state = result; error = failure
        }
    }
    // A replacement Settings model must not race an already accepted OS write.
    // It owns a fresh status read afterward, without registering a second time.
    func inheritRegistration(from previous: LoginItemViewModel?) {
        guard !retired, mutation == nil, let previous, previous !== self, let pending = previous.mutation else { return }
        _ = cancelRead(); cancelSettingsOpen(); changing = true
        mutation = Task {
            defer { changing = false; mutation = nil }
            await pending.value
            mutationFailure = previous.mutationFailure
            guard !retired else { return }
            let result = await service.state()
            guard !retired else { return }
            state = result; error = mutationFailure
        }
    }
    private func openSettings() {
        guard canOpenSystemSettings, settingsOpen == nil else { return }
        openingSettings = true
        let generation = UUID(); openGeneration = generation
        settingsOpen = Task {
            defer { if openGeneration == generation { settingsOpen = nil; openingSettings = false } }
            guard !retired, active, !Task.isCancelled else { return }
            await service.openSystemSettings()
        }
    }
    func cancelSettingsOpen() {
        openGeneration = UUID(); settingsOpen?.cancel(); settingsOpen = nil; openingSettings = false
    }
    func setActive(_ value: Bool) { if !retired { active = value } }
    func cancelRead() -> Task<Void, Never>? {
        revision = UUID(); read?.cancel(); read = nil; loading = false
        return mutation
    }
    func waitForMutation() async { await mutation?.value }
    func waitForSettingsOpen() async { await settingsOpen?.value }
    func retire() { active = false; retired = true; onAction = { _ in }; _ = cancelRead(); cancelSettingsOpen() }
    func stop() async { active = false; await cancelRead()?.value }
}
