import SwiftUI

/// The web CLIs tab's "CLI integration" card. A Section for a grouped Form; the caller owns the
/// Form so every settings tab shares one card style. Kept separate from the hooks card because the
/// web tab puts "Default agent" between the two.
struct CLIIntegrationSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section {
            Text("Use your installed tools and existing sign-ins.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(ManagedCLI.required) { cli in CLIStatusRow(model: model, cli: cli) }
            if let error = model.probeError { Text(error).foregroundStyle(Theme.danger) }
            if let error = model.actionError { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            SettingsSectionHeader(title: String(localized: "CLI integration"), busy: model.probing) {
                Button("Refresh", action: model.refresh).disabled(model.probing)
                    .accessibilityIdentifier("cli-refresh")
            }
        }
    }
}

/// The Integrations tab's "GitHub webhooks" card: pull request events delivered to automations
/// as they happen, not on the next poll. It holds the gh extension the forwarders run, so what
/// forwarding needs and whether it is on are read in one place.
struct WebhookForwardingSection: View {
    let model: WebhookForwardingViewModel
    let clis: CLISettingsViewModel
    var body: some View {
        Section("GitHub webhooks") {
            ForEach(ManagedCLI.webhooks) { cli in CLIStatusRow(model: clis, cli: cli) }
            SettingsRow(title: String(localized: "Forward webhooks to automations"),
                        caption: String(localized: "Pull request events reach automations as they happen. When disabled or unavailable, Cascade checks for updates on its regular schedule.")) {
                Toggle("Forward webhooks to automations", isOn: Binding(get: { model.enabled },
                                                                        set: { value in Task { await model.setEnabled(value) } }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(model.settings == nil || model.saving)
                    .accessibilityIdentifier("settings-forward-webhooks")
            }
            if let status = model.status(extensionInstalled: clis.availability[ManagedCLI.ghWebhook.rawValue]?.present) {
                Text(status).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(Theme.warn).textSelection(.enabled)
            }
        }
    }
}

/// The Integrations tab's "Simulator preview" card: what the workspace's Simulator panel needs.
/// Optional, so it stays out of first-run setup.
struct SimulatorPreviewSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section("Simulator preview") {
            Text("Simulator preview needs Node.js 20 or later in your terminal. Cascade downloads its preview tool automatically when first used.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(ManagedCLI.simulatorPreview) { cli in CLIStatusRow(model: model, cli: cli) }
        }
    }
}

private struct CLIStatusRow: View {
    let model: CLISettingsViewModel
    let cli: ManagedCLI
    var body: some View {
        let state = model.availability[cli.rawValue]
        SettingsStatusRow(title: cli.title, status: model.label(cli), tone: tone(state),
                          statusIdentifier: "cli-status-\(cli.rawValue)") {
            let outdated = state?.outdated(for: cli) == true
            // serve-sim is fetched on use: what it lacks is Node, which has its own row.
            if cli != .serveSim, state?.present == false || outdated {
                Button(LocalizedStringKey(outdated ? "Update" : "Install")) { model.openGuide(cli) }
                if let command = model.installCommand(cli) {
                    Button(LocalizedStringKey(command.hasPrefix("brew ") ? "Copy Homebrew Command" : "Copy Install Command")) {
                        model.copyInstall(cli)
                    }.help(command)
                }
            }
            if cli.loginCommand != nil {
                Button("Copy Login Command") { model.copyLogin(cli) }.help(cli.loginCommand ?? "")
            }
        }
    }

    /// Mirrors `CLIAvailability.label(for:)`. `authed` is only probed for CLIs that have a
    /// sign-in check (gh/acli), so nil means "not applicable" or "couldn't tell" — a warning tint
    /// there would contradict the "Installed" label sitting next to it.
    private func tone(_ state: CLIAvailability?) -> ThemeTone {
        guard let state, state.present else { return .neutral }
        if state.outdated(for: cli) { return .warning }
        switch state.authed {
        case true: return .success
        case false: return .warning
        default: return cli.supportsHooks || cli.isExtension || cli.isSimulatorPreview ? .success : .neutral
        }
    }
}

/// Reopens the first-run welcome. A card of its own at the top of the page: it covers the tools
/// and the hooks alike, and the welcome reuses the CLI card, which must not offer to open itself.
struct SetupAssistantSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section {
            // Not a `SettingsRow`: `LabeledContent` lines its control up with the title's baseline,
            // which leaves a button beside a two-line label sitting high.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup assistant")
                    Text("Walks through installing the tools and agent hooks again.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Setup Assistant…", action: model.showWelcome).accessibilityIdentifier("cli-show-welcome")
            }
        }
    }
}

/// The web CLIs tab's "Workflow hooks" card.
struct WorkflowHooksSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section("Workflow hooks") {
            Text("Hooks report when an agent starts and finishes a turn. Installing or removing hooks preserves your other configuration.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(ManagedCLI.allCases.filter(\.supportsHooks)) { cli in
                SettingsStatusRow(title: cli.title, status: model.hookLabel(cli),
                                  tone: model.hooks[cli.rawValue] == "installed" ? .success : .neutral,
                                  statusIdentifier: "hook-status-\(cli.rawValue)", busy: model.changing == cli) {
                    Button(model.hookAction(cli)) {
                        model.requestToggleHook(cli)
                    }.disabled(!model.canChange(cli)).accessibilityIdentifier("hook-toggle-\(cli.rawValue)")
                }
            }
            if let error = model.hookError { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            if let message = model.message { Text(message).foregroundStyle(Theme.textSecondary) }
        }
    }
}

/// Claude Code reports its real context window only to its status line. Sessions the app launches
/// get Cascade's for that launch alone; this installs it for the ones started by hand too.
struct AgentStatusLineSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section("Context status line") {
            Text("Show context usage for Claude Code sessions started outside Cascade. Sessions started here already report it. Your existing status line is preserved.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            SettingsStatusRow(title: ManagedCLI.claude.title, status: model.statusLineLabel,
                              tone: model.statusLineInstalled ? .success : .neutral,
                              statusIdentifier: "statusline-status", busy: model.changingStatusLine) {
                Button(LocalizedStringKey(model.statusLineInstalled ? "Remove status line" : "Install status line"), action: model.requestToggleStatusLine)
                    .disabled(!model.canChangeStatusLine).accessibilityIdentifier("statusline-toggle")
            }
        }
    }
}
