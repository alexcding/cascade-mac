import SwiftUI

/// The first-run welcome sheet. Every page can be skipped: nothing here is required to open the
/// app, and Settings > CLIs offers the same controls afterwards.
struct WelcomeView: View {
    let model: WelcomeViewModel
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: WelcomeIntroPage()
                case .tools: WelcomeToolsPage(model: model)
                case .hooks: WelcomeHooksPage(model: model)
                case .done: WelcomeDonePage(model: model)
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
            Button(model.isLast ? "Done" : "Continue") { if model.isLast { model.finish() } else { model.next() } }
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
            Text(title).font(.system(size: 20, weight: .semibold)).padding(.top, 12)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
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
            WelcomeHeader(title: "Welcome to Craft",
                          subtitle: "One place for your pull requests, tickets and the coding agents working on them.") {
                WelcomeAppIcon()
            }
            VStack(alignment: .leading, spacing: 18) {
                point("terminal", "It drives the tools you already use",
                      "Craft runs Claude Code, Codex, the GitHub CLI and the Atlassian CLI from your machine, with the sign-ins they already have. It stores no credentials of its own.")
                point("arrow.triangle.branch", "One session per worktree",
                      "Each session is an agent on its own git worktree, linked to the pull request or ticket it was started from.")
                point("bell", "It knows when an agent is waiting",
                      "With hooks installed, agents report when a turn starts and ends, so the sidebar and notifications show which session needs you.")
            }
            .padding(.horizontal, 56).padding(.top, 20)
            Spacer(minLength: 0)
            Text("The next two pages check your tools and install the hooks. It takes about a minute.")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.bottom, 16)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.accent)
                .frame(width: 26, alignment: .center).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The same card Settings > CLIs shows, so what a user learns here is where they find it later.
private struct WelcomeToolsPage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "Check your tools",
                          subtitle: "Install what is missing in your terminal, then press Refresh. You need at least one agent; the GitHub and Atlassian tools are only needed for the pages that use them.") {
                WelcomeTerminalCard(lines: ["claude --version", "gh auth login", "acli jira auth login"])
            }
            Form { CLIIntegrationSection(model: model.clis) }
                .formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
}

/// Hooks and the status line are both entries Craft merges into an agent's configuration, so
/// the status line sits under Claude Code's hook rather than on a page of its own.
private struct WelcomeHooksPage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: "Install agent hooks",
                          subtitle: "Hooks tell Craft when an agent starts and finishes a turn. Craft merges its entries into the agent's configuration and removes only its own.") {
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
                            Text("\(cli.title) is not installed, so there is nothing to set up yet. You can install its hooks later from Settings > CLIs.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        SettingsStatusRow(title: "Turn hooks", status: model.clis.hookLabel(cli),
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
        SettingsStatusRow(title: "Context status line", status: model.clis.statusLineLabel,
                          tone: model.clis.statusLineInstalled ? .success : .neutral,
                          statusIdentifier: "welcome-statusline-status", busy: model.clis.changingStatusLine) {
            Button(model.clis.statusLineInstalled ? "Remove status line" : "Install status line", action: model.clis.requestToggleStatusLine)
                .disabled(!model.canChangeStatusLine).accessibilityIdentifier("welcome-statusline-toggle")
        }
        Text("Claude Code reports its context window only to its status line. Sessions Craft launches report it already; install this so the ones you start yourself do too. Your own status line keeps drawing.")
            .font(.caption).foregroundStyle(Theme.textSecondary)
    }
}

private struct WelcomeDonePage: View {
    let model: WelcomeViewModel

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(title: model.remaining.isEmpty ? "You're all set" : "Almost there",
                          subtitle: model.remaining.isEmpty
                              ? "Your tools and hooks are in place."
                              : "Craft works without these, but the pages that depend on them stay empty.") {
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
                Text("Everything on these pages stays available in Settings > CLIs.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 24)
        }
    }
}
