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
            return String(localized: "Install the gh webhook extension to forward events. Cascade will keep checking for updates on its regular schedule.")
        }
        if settings.paused { return String(localized: "Automations are paused. Forwarded events are ignored until you resume them.") }
        guard settings.forwardWebhooks else { return String(localized: "Webhook forwarding is off. Automations check pull request changes on the regular refresh schedule.") }
        if !settings.projects.isEmpty, settings.projects.allSatisfy({ $0.state == .disabled }) {
            return String(localized: "Every project has forwarding turned off in its settings.")
        }
        if settings.forwardable.isEmpty { return String(localized: "No enabled pull request automation needs webhook forwarding.") }
        let running = settings.forwardable.filter(settings.forwarding.contains)
        return running.count == settings.forwardable.count
            ? String(localized: "Repositories forwarding events: \(running.count).")
            : String(localized: "Repositories forwarding events: \(running.count) of \(settings.forwardable.count). Cascade checks the rest on its regular schedule.")
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
            (String(localized: "Blocked"), .warning,
             String(localized: "\(project.repo) already has a gh webhook forward hook, left by a forwarder that quit or crashed, or a teammate forwarding it now. GitHub allows one. Fix removes it; a teammate's forwarder would stop."))
        case .running: (String(localized: "Forwarding"), .success, project.repo)
        case .starting: (String(localized: "Starting"), .neutral, project.repo)
        case .retrying:
            (String(localized: "Retrying"), .warning,
             "\(project.repo) · \(project.error ?? String(localized: "The forwarder could not start."))")
        case .idle:
            (String(localized: "Idle"), .neutral,
             "\(project.repo) · \(String(localized: "No enabled pull request automation covers this project."))")
        case .off: (String(localized: "Off"), .neutral, project.repo)
        case .disabled:
            (String(localized: "Off"), .neutral, "\(project.repo) · \(String(localized: "Turned off in the project's settings."))")
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
