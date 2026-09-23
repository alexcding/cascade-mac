import Foundation
import Observation

/// The first-run welcome: what Craft needs from the machine, in the order a new user can fix
/// it — the tools first, then the hooks that only make sense once an agent is installed.
@MainActor @Observable final class WelcomeViewModel {
    enum Page: Int, CaseIterable { case welcome, tools, hooks, done }
    enum Action: Equatable { case cli(CLISettingsViewModel.Action), finished }
    @ObservationIgnored var onAction: (Action) -> Void = { _ in }
    let clis: CLISettingsViewModel
    private(set) var page: Page = .welcome
    private(set) var retired = false

    init(clis: CLISettingsViewModel) {
        self.clis = clis
        clis.onAction = { [weak self] in self?.onAction(.cli($0)) }
    }

    /// A hook or status-line edit is rewriting the agent's configuration; the sheet stays until it lands.
    var busy: Bool { clis.changing != nil || clis.changingStatusLine }
    var isFirst: Bool { page == Page.allCases.first }
    var isLast: Bool { page == Page.allCases.last }

    func connect(_ service: any CLISettingsService) {
        guard !retired else { return }
        clis.connect(service); clis.refresh()
    }
    func next() {
        guard !retired, let following = Page(rawValue: page.rawValue + 1) else { return }
        page = following
    }
    func back() {
        guard !retired, let previous = Page(rawValue: page.rawValue - 1) else { return }
        page = previous
    }
    func finish() { if !retired && !busy { onAction(.finished) } }

    /// Nil until the probe answers: an unknown tool is not reported as missing.
    func present(_ cli: ManagedCLI) -> Bool? { clis.availability[cli.rawValue]?.present }
    /// Hooks are written into the agent's own configuration, so there is nothing to set up
    /// for an agent that is not installed.
    func canChangeHook(_ cli: ManagedCLI) -> Bool { !retired && present(cli) != false && clis.canChange(cli) }
    var canChangeStatusLine: Bool { !retired && present(.claude) != false && clis.canChangeStatusLine }

    /// What the last page reports as still open. Empty means everything the app can see is set up.
    var remaining: [String] {
        var items: [String] = []
        for cli in ManagedCLI.required {
            guard let state = clis.availability[cli.rawValue] else { continue }
            if !state.present { items.append("\(cli.title) is not installed.") }
            else if state.authed == false { items.append("\(cli.title) is not signed in.") }
        }
        for cli in ManagedCLI.allCases where cli.supportsHooks && present(cli) == true {
            if let status = clis.hooks[cli.rawValue], status != "installed" {
                items.append(status == "outdated" ? "\(cli.title) hooks have an update." : "\(cli.title) hooks are not installed.")
            }
        }
        if present(.claude) == true, let status = clis.hooks[APICLISettingsService.statusLineKey], status != "installed" {
            items.append("The Claude Code context status line is not installed.")
        }
        return items
    }

    func stop() async { await clis.stop() }
    func retire() { retired = true; onAction = { _ in }; clis.retire() }
}
