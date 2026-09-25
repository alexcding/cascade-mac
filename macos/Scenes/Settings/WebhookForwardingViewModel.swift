import Foundation
import Observation

/// Settings → Integrations' GitHub webhooks row: whether pull request events are forwarded to
/// automations as they happen, and what the forwarders are doing now. It reads and writes the
/// automation settings; the Automation screen keeps only the switch that pauses everything.
@MainActor @Observable final class WebhookForwardingViewModel {
    private(set) var settings: AutomationSettings?
    private(set) var saving = false
    private(set) var error: String?
    private(set) var retired = false
    /// The repo whose leftover forwarder hook is being removed.
    private(set) var fixing: String?
    @ObservationIgnored private var service: (any AutomationService)?
    @ObservationIgnored private var generation = UUID()

    /// On unless turned off: forwarding only runs for repos a pull request automation that is on covers.
    var enabled: Bool { settings?.forwardWebhooks ?? true }

    var status: String? { status(extensionInstalled: nil) }

    /// What forwarding is doing, given whether the gh webhook extension is installed (nil: not probed yet).
    func status(extensionInstalled: Bool?) -> String? {
        guard let settings else { return nil }
        if settings.forwardWebhooks, extensionInstalled == false {
            return "Install the gh webhook extension to forward events. Until then, polling catches every change."
        }
        if settings.paused { return "Automations are paused: forwarded events are ignored until they are back on." }
        guard settings.forwardWebhooks else { return "Polling only: automations see pull request changes on the next poll." }
        if !settings.projects.isEmpty, settings.projects.allSatisfy({ $0.state == .disabled }) {
            return "Every project has forwarding turned off in its settings."
        }
        if settings.forwardable.isEmpty { return "No pull request automation that is on covers these projects yet." }
        let running = settings.forwardable.filter(settings.forwarding.contains)
        return running.count == settings.forwardable.count
            ? "Forwarding \(running.count) repo\(running.count == 1 ? "" : "s")."
            : "Forwarding \(running.count) of \(settings.forwardable.count) repos. Polling covers the rest."
    }

    func connect(_ service: (any AutomationService)?) {
        guard !retired else { return }
        self.service = service; generation = UUID(); saving = false; error = nil
        if service == nil { settings = nil }
    }

    func refresh() {
        guard !retired, let service else { return }
        let token = generation
        Task { [weak self] in
            do {
                let value = try await service.settings()
                guard let self, !self.retired, self.generation == token else { return }
                self.settings = value; self.error = nil
            } catch {
                guard let self, !self.retired, self.generation == token else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard !retired, !saving, let service else { return }
        let token = generation
        saving = true; error = nil
        defer { if generation == token { saving = false } }
        do {
            let updated = try await service.updateSettings(paused: nil, forwardWebhooks: value)
            if !retired, generation == token { settings = updated }
        } catch {
            if !retired, generation == token { self.error = error.localizedDescription }
        }
    }

    /// Every project with a repo, with its forwarding status; a blocked one offers Fix.
    var projects: [ForwardingProject] { settings?.projects ?? [] }

    /// What a project's forwarder is doing, for its row.
    static func detail(_ project: ForwardingProject) -> (label: String, tone: ThemeTone, caption: String) {
        switch project.state {
        case .hookExists:
            ("Blocked", .warning,
             "\(project.repo) already has a gh webhook forward hook, left by a forwarder that quit or crashed, or a teammate forwarding it now. GitHub allows one. Fix removes it; a teammate's forwarder would stop.")
        case .running: ("Forwarding", .success, project.repo)
        case .starting: ("Starting", .neutral, project.repo)
        case .retrying: ("Retrying", .warning, "\(project.repo) · \(project.error ?? "The forwarder could not start.")")
        case .idle: ("Idle", .neutral, "\(project.repo) · No pull request automation that is on covers this project.")
        case .off: ("Off", .neutral, project.repo)
        case .disabled: ("Off", .neutral, "\(project.repo) · Turned off in the project's settings.")
        }
    }

    /// Remove the hook that blocks a repo's forwarder, and start it again.
    func fix(_ repo: String) async {
        guard !retired, fixing == nil, let service else { return }
        let token = generation
        fixing = repo; error = nil
        do {
            try await service.fixForwarder(repo: repo)
            let value = try await service.settings()
            guard !retired, generation == token else { return }
            fixing = nil; settings = value
        } catch {
            guard !retired, generation == token else { return }
            fixing = nil; self.error = error.localizedDescription
            return
        }
        // The backend starts the forwarder on its next sync, within ten seconds.
        try? await Task.sleep(for: .seconds(12))
        guard !retired, generation == token else { return }
        refresh()
    }

    func disconnect() { generation = UUID(); service = nil; saving = false; fixing = nil }
    func retire() { retired = true; disconnect() }
}
