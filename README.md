# Craft

**One workspace for your coding agents, pull requests, and tickets. Built for Mac.**

Running a few coding agents is easy. Keeping track of their branches, terminals,
changes, and reviews is the hard part.

Craft brings that work together. Start Claude Code or Codex from a branch, GitHub
pull request, or Jira ticket. Give each task its own git worktree. Keep the terminal,
browser, files, and diff together, then switch tasks without reconstructing your
context.

Built in the open with Swift, SwiftUI, AppKit, and Rust.

[Get started](#get-started) · [Your first session](#your-first-session) ·
[Contribute](#help-build-craft) · [Report an issue](https://github.com/alexcding/craft-mac/issues)

![Craft dashboard showing pull requests, review requests, Jira tickets, and agent usage](docs/images/dashboard.png)

## Why Craft?

- **Give every task room to work.** Run agents side by side in separate git worktrees.
  Each worktree is a checkout with its own branch and files, so you can work on a
  feature while another session investigates a bug.
- **Keep the context with the code.** Open a PR, ticket, or documentation page next
  to its terminal. Saved tabs, pinned sessions, and a project sidebar help you pick
  up where you left off.
- **Review before you ship.** Inspect working changes and branch history, open
  files in the editor, discard individual change blocks with a preview, and commit
  and push from the session.
- **See what needs your attention.** The dashboard separates your PRs from your
  review queue and shows CI status. The menu bar keeps review requests and available
  Claude/Codex usage information close by.
- **Use the tools you already know.** Agents run in real Ghostty-powered terminals.
  GitHub uses your signed-in `gh`; Jira uses `acli`. Open a worktree in your preferred
  IDE or Git client whenever you need it.
- **Make repeatable work easier.** Save multi-step agent workflows per project,
  follow their progress, and optionally transition linked Jira tickets when a PR
  merges.

You can start with a local repository and a shell. Add agents, GitHub, and Jira as
you need them.

## Get started

Build and run Craft from source:

1. Use an **Apple Silicon Mac**, with **macOS 14 or later** as the app's deployment
   target. Building the current source requires **Xcode 26 or later** for the macOS
   26 SDK; your build machine must support that Xcode version.
2. Clone the repository and open the Xcode project:

   ```bash
   git clone https://github.com/alexcding/craft-mac.git
   cd craft-mac
   open macos/Craft.xcodeproj
   ```

3. Select **Craft → My Mac** and press **⌘R**.

The build prepares the Rust backend and terminal helper, downloads the pinned
Ghostty runtime, and installs Rust through rustup if Cargo is missing. The first
build needs network access and takes longer; subsequent builds are incremental.
If you already have Rust installed, the backend requires **Rust 1.88 or later**.
Bootstrap output is saved to `macos/.build/bootstrap.log`.

### Connect only what you use

| Tool | What it adds |
| --- | --- |
| [GitHub CLI (`gh`)](https://cli.github.com) | Pull requests, review requests, and CI status. Sign in with `gh auth login`. |
| Claude Code or Codex | Agent sessions using your installed CLI and its existing account. Choose **Shell only** to work without an agent. |
| [Atlassian CLI (`acli`)](https://developer.atlassian.com/cloud/acli/guides/install-macos/) | Jira tickets, sprint data, and status transitions. Sign in with `acli jira auth login`. |
| [`gh-webhook`](https://github.com/cli/gh-webhook) | Faster GitHub updates. Optional; polling works without it. |

The first-launch guide checks your tools and offers optional agent hooks. You can
revisit these controls in **Settings → Integrations**. Hooks report agent turn boundaries
and are required for multi-step workflows; ordinary terminal sessions work without
them.

Some optional Jira features, including board-column configuration and Fix Version
automation, also need a Jira API token in Settings. Craft itself has no separate
account to create or hosted backend to deploy.

## Your first session

1. **Add a project.** Choose **New Project** in the sidebar, give it a name, and
   select an existing local Git checkout. Craft detects its GitHub repository.
   Add a Jira project key if you use Jira.
2. **Start a task.** Use the project's **+** button or **⌘N**. Enter a branch name,
   PR URL, or Jira ticket URL, choose the base branch, and select Claude, Codex, or
   Shell only. Craft creates or reuses the matching worktree.
3. **Work with the context beside you.** Give the agent a task, keep the relevant
   pages open, and inspect its files and changes. Start another session when you
   want to work on a different branch.
4. **Review and share your work.** Check the diff, make any edits, then use
   **Commit and Push**. Follow the PR and its CI status from the dashboard.

Closing the main window keeps Craft and its sessions running. **⌘Q** explicitly
stops the terminals; saved sessions can resume an agent conversation when its
conversation ID is available. The detached terminal daemon also lets Craft
reattach to running shells after an unexpected app exit.

## Make it your workflow

**For repeated agent tasks:** create a recipe in a project's **Workflows** section.
Choose an agent and give it ordered prompts, such as investigate, implement, and
review. Placeholders like `{branch}`, `{worktree}`, and `{url}` tie the recipe to
the current session. Run it with agent hooks installed to follow step progress.

**For teams using Jira:** browse tickets or the native Sprint Board, filter the
work you care about, and start sessions from ticket links. In **Automation**, choose
the status linked tickets should move to after a PR merges. Fix Version assignment
is optional.

**For your Mac setup:** choose light or dark appearance, customize terminal and
editor fonts and themes, and set your preferred IDE and Git client. Xcode projects
can select a scheme and run destination, build, and launch from the workspace.

## How it works

Craft's app is SwiftUI and AppKit, with a Rust backend linked into the same process.
The backend refreshes GitHub and Jira data in the background and stores snapshots
in SQLite. Screens read the saved snapshot immediately and update when fresh data
arrives.

Ghostty renders the terminals; a separate Rust daemon owns the shells and their
terminal state. WebKit hosts context pages and a bundled diff renderer. The diff
page has no network access and receives its data from the native app.

Projects, session records, and settings live locally under
`~/Library/Application Support/Craft`. Git checkouts stay on disk, and agents keep
their own conversation stores. GitHub, Jira, agents, and pages you open still use
their respective online services. See [data recovery](docs/DATA-RECOVERY.md) for
backup and restore details.

| Where to look | What you'll find |
| --- | --- |
| [`macos/Scenes/`](macos/Scenes) | Dashboard, sessions, editor, Jira, workflows, and settings |
| [`macos/Services/`](macos/Services) | Terminal, backend, browser, and workspace services |
| [`crates/craft-backend/`](crates/craft-backend) | API, background sync, Git/CLI integrations, and SQLite stores |
| [`crates/craft-ptyd/`](crates/craft-ptyd) | Detached terminal daemon |
| [`crates/craft-vt/`](crates/craft-vt) | Headless Ghostty runtime for terminal snapshots |
| [`AGENTS.md`](AGENTS.md) | Contributor working guide, architecture, and coding conventions |

## Help build Craft

Craft is being built around real development work. If you try it, your experience
can help shape what comes next. You don't need to know both Swift and Rust to
contribute, and you don't need to write code to make a useful contribution.

- **Try one real task.** Tell us where setup, navigation, or the agent workflow
  felt confusing. A clear description of what you expected is useful feedback.
- **Report a bug.** [Open an issue](https://github.com/alexcding/craft-mac/issues/new)
  with steps to reproduce, expected and actual behavior, your macOS/Xcode versions,
  and relevant logs or screenshots. Remove credentials and private project details.
- **Improve a small piece.** Setup documentation, keyboard navigation,
  accessibility, error messages, and regression tests are useful starting points.
- **Bring a workflow.** Show how you use agents, worktrees, or Jira, and describe
  the friction you'd like Craft to remove. Open an issue before a large change so
  we can work through the approach together.
- **Help people find it.** Star the repository, share it with a teammate, or post
  a walkthrough of a task you completed with Craft.

### Sending a pull request

Fork the repository, create a branch, and read [AGENTS.md](AGENTS.md) before making
changes. Keep the PR focused, explain the problem and resulting behavior, and
include screenshots for UI changes. Describe how you verified it and any checks
you couldn't run. Small, well-explained contributions are welcome.

After the first Xcode build has prepared the native dependencies, run the checks
that cover your change:

```bash
# Rust backend
cargo test --manifest-path crates/craft-backend/Cargo.toml

# Terminal daemon and snapshots
cargo test --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots

# Native app unit tests
xcodebuild test -project macos/Craft.xcodeproj -scheme Craft \
  -derivedDataPath macos/.build/xcode -only-testing:CraftTests
```

Swift Testing can report success after running zero tests when filtered by a single
function name. Use the target-level command above and check the executed test count.

For deeper work, see the [native app guide](macos/README.md),
[terminal snapshot protocol](crates/craft-ptyd/SNAPSHOTS.md), and
[Ghostty patch guide](macos/patches/ghostty/README.md). Direct-distribution packaging
is documented in the [packaging guide](macos/README.md#direct-distribution-packaging).

## Acknowledgments and licensing

Craft builds on [Ghostty](https://github.com/ghostty-org/ghostty),
[GhosttyTerminal](https://github.com/alexcding/ghostty-terminal-spm),
[CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor), and
[Sparkle](https://github.com/sparkle-project/Sparkle), alongside the CLI tools that
connect it to your work.

The Rust crates declare the **ISC** license in their manifests
([backend](crates/craft-backend/Cargo.toml), [terminal daemon](crates/craft-ptyd/Cargo.toml),
[VT runtime](crates/craft-vt/Cargo.toml)). Third-party dependencies retain their own
licenses.
