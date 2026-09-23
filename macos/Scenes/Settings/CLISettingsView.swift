import SwiftUI

/// The web CLIs tab's "CLI integration" card. A Section for a grouped Form; the caller owns the
/// Form so every settings tab shares one card style. Kept separate from the hooks card because the
/// web tab puts "Default agent" between the two.
struct CLIIntegrationSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section {
            Text("Craft uses your installed tools and their existing sign-in sessions.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(ManagedCLI.required) { cli in CLIStatusRow(model: model, cli: cli) }
            if let error = model.probeError { Text(error).foregroundStyle(Theme.danger) }
            if let error = model.actionError { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            SettingsSectionHeader(title: "CLI integration", busy: model.probing) {
                Button("Refresh", action: model.refresh).disabled(model.probing)
                    .accessibilityIdentifier("cli-refresh")
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
            Text("Run on an iOS simulator to see it in the session's Simulator panel. Craft streams it with Expo's serve-sim, fetched automatically, which needs Node.js 20 or later. Any Node your terminal finds works: Homebrew, the Node.js installer, nvm, fnm, Volta, asdf or mise.")
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
                Button(outdated ? "Update" : "Install") { model.openGuide(cli) }
                if let command = model.installCommand(cli) {
                    Button(command.hasPrefix("brew ") ? "Copy Homebrew Command" : "Copy Install Command") {
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
            Text("Hooks report when an agent starts and finishes a turn. Craft merges its entries into the agent's configuration and removes only its own entries.")
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
/// get Craft's for that launch alone; this installs it for the ones started by hand too.
struct AgentStatusLineSection: View {
    let model: CLISettingsViewModel
    var body: some View {
        Section("Context status line") {
            Text("Claude Code tells only its status line how large its context window is. Sessions Craft launches report it already. Install this so sessions you start yourself do too. Your own status line keeps drawing, and is put back when this is removed.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            SettingsStatusRow(title: ManagedCLI.claude.title, status: model.statusLineLabel,
                              tone: model.statusLineInstalled ? .success : .neutral,
                              statusIdentifier: "statusline-status", busy: model.changingStatusLine) {
                Button(model.statusLineInstalled ? "Remove status line" : "Install status line", action: model.requestToggleStatusLine)
                    .disabled(!model.canChangeStatusLine).accessibilityIdentifier("statusline-toggle")
            }
        }
    }
}
