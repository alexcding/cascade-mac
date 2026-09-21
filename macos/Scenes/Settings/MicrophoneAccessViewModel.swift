import Foundation
import Observation

@MainActor @Observable final class MicrophoneAccessViewModel {
    private(set) var retired = false
    private(set) var active = false {
        didSet {
            guard oldValue != active else { return }
            if active { refresh() } else { cancelRead() }
        }
    }
    private(set) var status: MicrophoneAccessStatus?
    private(set) var loading = false
    private(set) var requesting = false
    @ObservationIgnored private let service: any MicrophoneAccessService
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var settingsOpen: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    init(service: any MicrophoneAccessService) { self.service = service }

    var authorized: Bool { status == .authorized }
    /// The system prompt only appears once; afterwards the grant lives in System Settings.
    var canRequest: Bool { !retired && active && status == .notDetermined && !loading && !requesting }
    /// A policy restriction cannot be lifted from the privacy pane, so only a denial offers it.
    var canOpenSystemSettings: Bool { !retired && active && status == .denied && settingsOpen == nil }
    var statusText: String {
        guard let status else { return "Checking microphone access…" }
        switch status {
        case .notDetermined: return "Not requested. Craft asks the first time a session needs the microphone."
        case .authorized: return "Allowed. Sessions and agents running in Craft can use the microphone."
        case .denied: return "Denied. Allow Craft under Privacy & Security › Microphone."
        case .restricted: return "Restricted by a system policy; Craft cannot request it."
        }
    }

    func refresh() {
        guard !retired, active, read == nil, !requesting else { return }
        loading = true
        let requestRevision = revision
        read = Task {
            let result = await service.status()
            guard !retired, !Task.isCancelled, revision == requestRevision else { return }
            status = result; loading = false; read = nil
        }
    }
    func requestAccess() {
        guard canRequest, request == nil else { return }
        cancelRead(); requesting = true
        request = Task {
            defer { requesting = false; request = nil }
            let result = await service.requestAccess()
            guard !retired else { return }
            status = result
        }
    }
    func openSystemSettings() {
        guard canOpenSystemSettings else { return }
        settingsOpen = Task {
            defer { settingsOpen = nil }
            guard !retired, active, !Task.isCancelled else { return }
            await service.openSystemSettings()
        }
    }
    /// The coordinator cancels a pending open when the page navigates away before it lands.
    func cancelSettingsOpen() { settingsOpen?.cancel(); settingsOpen = nil }
    func setActive(_ value: Bool) { if !retired { active = value } }
    /// Returns the cancelled read so `stop()` can drain it.
    @discardableResult func cancelRead() -> Task<Void, Never>? {
        let pending = read
        revision = UUID(); read?.cancel(); read = nil; loading = false
        return pending
    }
    func retire() {
        active = false; retired = true; cancelRead(); cancelSettingsOpen()
        request?.cancel(); request = nil; requesting = false
    }
}
