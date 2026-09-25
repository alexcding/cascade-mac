import SwiftUI

/// The first-run welcome sheet. Every page can be skipped: nothing here is required to open the
/// app, and Settings → Integrations offers the same controls afterwards.
struct WelcomeView: View {
    let model: WelcomeViewModel
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: ScrollView { WelcomeIntroPage() }
                case .tools: WelcomeToolsPage(model: model)
                case .hooks: WelcomeHooksPage(model: model)
                case .simulator: WelcomeSimulatorPage(model: model)
                case .done: ScrollView { WelcomeDonePage(model: model) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        // A fixed panel, the size of a system setup assistant: it never grows with the window.
        .frame(width: 620, height: 580)
        .interactiveDismissDisabled(model.busy)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.isFirst {
                Button("Back", action: model.back).accessibilityIdentifier("welcome-back")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(WelcomeViewModel.Page.allCases, id: \.self) { page in
                    Circle().fill(page == model.page ? Theme.accent : Theme.border).frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if !model.isLast {
                Button("Skip Setup", action: cancel).keyboardShortcut(.cancelAction)
                    .disabled(model.busy).accessibilityIdentifier("welcome-skip")
            }
            Button(LocalizedStringKey(model.isLast ? "Done" : "Continue")) { if model.isLast { model.finish() } else { model.next() } }
                .keyboardShortcut(.defaultAction).disabled(model.isLast && model.busy)
                .accessibilityIdentifier("welcome-continue")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

/// A page's title block, shared so the four pages open at the same height: the page's picture
/// on a tinted stage, then its title and one sentence.
private struct WelcomeHeader<Hero: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var hero: Hero

    var body: some View {
        VStack(spacing: 8) {
            hero.frame(maxWidth: .infinity).frame(height: 116)
                .background(Theme.accentBackground)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title)).font(.system(size: 20, weight: .semibold)).padding(.top, 12)
            Text(LocalizedStringKey(subtitle)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 48)
        }
        .padding(.bottom, 8)
    }
}

/// The app's own icon, as the Dock shows it.
private struct WelcomeAppIcon: View {
    var size: CGFloat = 84
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// A small terminal window, drawn rather than shipped: it follows the palette in both themes.
private struct WelcomeTerminalCard: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.border).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(Theme.accent)
                        Text(line)
                    }
                }
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paneBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
    }
}

private struct WelcomeIntroPage: View {
    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "Welcome to Cascade",
                          subtitle: "Your pull requests, tickets, and coding agents in one workspace.") {
                WelcomeAppIcon()
            }
            VStack(alignment: .leading, spacing: 18) {
                point("terminal", "Use the tools you already know",
                      "Use your installed tools and existing sign-ins. Choose Shell only to work without an agent.")
                point("arrow.triangle.branch", "One session per worktree",
                      "Each session has its own Git worktree and terminal. Start from a branch name, pull request, or Jira ticket.")
                point("bell", "See which session needs you",
                      "Agent hooks update the sidebar and notify you when a session needs attention.")
            }
            .padding(.horizontal, 56).padding(.top, 20)
            Spacer(minLength: 0)
            Text("Set up your tools, agent hooks, and optional Simulator preview. You can skip setup and return later.")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.bottom, 16)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.accent)
                .frame(width: 26, alignment: .center).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The same card Settings → Integrations shows, so what a user learns here is where they find it later.
private struct WelcomeToolsPage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "Check your tools",
                          subtitle: "Install the tools you need, then click Refresh. GitHub and Jira features require their command-line tools. Agents are optional.") {
                WelcomeTerminalCard(lines: ["claude --version", "gh auth login", "acli jira auth login"])
            }
            Form { CLIIntegrationSection(model: model.clis) }
                .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

/// Hooks and the status line are both entries Cascade merges into an agent's configuration, so
/// the status line sits under Claude Code's hook rather than on a page of its own.
private struct WelcomeHooksPage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "Install agent hooks",
                          subtitle: "Hooks report when an agent starts and finishes a turn. Installing or removing hooks preserves your other configuration.") {
                // An agent's turn ending, arriving at the app.
                HStack(spacing: 18) {
                    WelcomeTerminalCard(lines: ["claude", "turn finished"])
                    Image(systemName: "arrow.right").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accent)
                    WelcomeAppIcon(size: 64)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "bell.badge.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                                .padding(5).background(Circle().fill(Theme.paneBackground)).offset(x: 8, y: -6)
                        }
                }
            }
            Form {
                ForEach(ManagedCLI.allCases.filter(\.supportsHooks)) { cli in
                    Section(cli.title) {
                        if model.present(cli) == false {
                            Text("Install \(cli.title) first. You can add its hooks later in Settings → Integrations.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        SettingsStatusRow(title: String(localized: "Turn hooks"), status: model.clis.hookLabel(cli),
                                          tone: model.clis.hooks[cli.rawValue] == "installed" ? .success : .neutral,
                                          statusIdentifier: "welcome-hook-status-\(cli.rawValue)", busy: model.clis.changing == cli) {
                            Button(model.clis.hookAction(cli)) { model.clis.requestToggleHook(cli) }
                                .disabled(!model.canChangeHook(cli)).accessibilityIdentifier("welcome-hook-toggle-\(cli.rawValue)")
                        }
                        if cli == .claude { statusLine }
                    }
                }
                if let error = model.clis.hookError {
                    Section { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var statusLine: some View {
        SettingsStatusRow(title: String(localized: "Context status line"), status: model.clis.statusLineLabel,
                          tone: model.clis.statusLineInstalled ? .success : .neutral,
                          statusIdentifier: "welcome-statusline-status", busy: model.clis.changingStatusLine) {
            Button(LocalizedStringKey(model.clis.statusLineInstalled ? "Remove status line" : "Install status line"), action: model.clis.requestToggleStatusLine)
                .disabled(!model.canChangeStatusLine).accessibilityIdentifier("welcome-statusline-toggle")
        }
        Text("Show context usage for Claude Code sessions started outside Cascade. Sessions started here already report it. Your existing status line is preserved.")
            .font(.caption).foregroundStyle(Theme.textSecondary)
    }
}

/// Optional, and says so: only iOS projects use it. The same card as Settings → Integrations.
private struct WelcomeSimulatorPage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "iOS Simulator preview",
                          subtitle: "Optional for iOS projects: run an app in Simulator to interact with it beside your session.") {
                // A run, arriving in the app's side panel.
                HStack(spacing: 18) {
                    WelcomeTerminalCard(lines: ["node --version", "v22"])
                    Image(systemName: "arrow.right").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accent)
                    Image(systemName: model.simulatorPreviewReady == true ? "iphone" : "iphone.slash")
                        .font(.system(size: 52, weight: .regular)).foregroundStyle(Theme.accent)
                }
            }
            Form { SimulatorPreviewSection(model: model.clis) }
                .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

private struct WelcomeDonePage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: model.remaining.isEmpty ? "Ready to start" : "Optional setup remaining",
                          subtitle: "You can finish setup later in Settings → Integrations.") {
                Image(systemName: model.remaining.isEmpty ? "checkmark.seal.fill" : "checklist")
                    .font(.system(size: 58, weight: .regular))
                    .foregroundStyle(model.remaining.isEmpty ? Theme.success : Theme.accent)
            }
            if !model.remaining.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.remaining, id: \.self) { item in
                        Label(item, systemImage: "circle").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 72).padding(.top, 18)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Text("Add a project from the sidebar to start your first session.").font(.system(size: 13))
                Text("All setup options are available in Settings → Integrations.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 24)
        }
    }
}
