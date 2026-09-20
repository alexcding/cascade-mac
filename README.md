# Craft

**A native macOS app for running coding agents on git worktrees, next to the pull requests
and tickets they are working on.**

Craft puts the whole loop in one window: pick a ticket or a pull request, start Claude Code
or Codex on its own worktree, watch it work in a real terminal, review the diff, and merge.
It reads GitHub, Jira and git through the CLIs you already have signed in, so there are no
tokens to paste and no hosted service behind it.

![Craft dashboard](docs/images/dashboard.png)

## What it does

- **Agent sessions, one per worktree.** A session is an agent running on its own git
  worktree, titled by the ticket or pull request it was started from. Several run side by
  side without touching each other's checkout.
- **Terminals that outlive the app.** Shells belong to a small detached daemon, so quitting,
  updating or crashing the app does not end a running agent. Reopen and they are still there,
  scrollback included. Rendering is Ghostty.
- **Review where the work happened.** Each session has a working-changes diff, commit
  history, a file browser and an editor beside its terminal.
- **Your queue, split the way you think about it.** The dashboard separates pull requests
  that are yours from the ones waiting on your review, with CI state on each.
- **Projects tie it together.** A project is one GitHub repository, an optional Jira query,
  a workspace folder and a color. When a pull request merges, its ticket moves to the state
  you chose.
- **A Jira sprint board**, native, for the tickets behind the work.
- **A menu-bar signal** for tasks and reviews, with Claude and Codex usage at a glance, so
  the window does not have to stay in front.
- **Agent hooks, if you want them.** Craft can add entries to Claude Code's and Codex's
  configuration that report when a turn starts and finishes, and a Claude status line that
  reports context use. It merges its own entries and removes only its own. A first-launch
  guide walks through it.
- **Deep links.** `craft://app/...` opens a project, a session or a terminal.

## Requirements

- macOS 14 or later, Apple Silicon.
- Xcode, to build it.
- [`gh`](https://cli.github.com), signed in. Optional: Atlassian's `acli` for Jira, and
  Claude Code or Codex for agent sessions.

Rust is installed for you on the first build if it is missing.

## Build and run

```bash
open macos/Craft.xcodeproj   # then press ⌘R
```

That is the whole setup. The scheme runs `macos/scripts/bootstrap.sh` before each build,
which installs rustup if needed, downloads the pinned Ghostty runtime, and builds the Rust
side. The first build takes a few minutes; later ones are incremental. Its log is
`macos/.build/bootstrap.log`.

## How it works

Two languages and nothing else: **Swift** for the app, **Rust** for everything behind it.

```text
gh / acli / git
      |
   poller  ── writes ──>  SQLite snapshots
                               |
                 Rust API (linked into the app)
                               |
        SwiftUI + AppKit: dashboard, sessions, board, tray
                               |
             craft-ptyd (detached) ── owns the shells
```

- **Snapshots, not live calls.** One poller talks to the CLIs and writes lean snapshots.
  Every screen reads a snapshot, which is instant, and a stale read triggers a refresh in
  the background. Request handlers never shell out. If something needs to be fresher, the
  fix belongs in the sync path.
- **The backend is a library.** The Rust API is linked into the app and called over a C ABI,
  so there is no port to manage and no child process. `--backend-path` or `--backend-url`
  runs the same app against a separate backend over HTTP.
- **The terminal is three pieces.** `craft-ptyd` owns the PTYs in its own session;
  GhosttyTerminal draws them; `craft-vt` is a headless Ghostty used to snapshot a terminal so
  it can be restored exactly.
- **Local data.** Everything lives in `~/Library/Application Support/Craft`: `craft.db` is
  durable configuration, `data.db` and `logs.db` are caches that can be rebuilt. Set
  `CRAFT_DATA_DIR` to put it elsewhere.

## Repository layout

| Path | What is there |
| --- | --- |
| `macos/` | The app, its tests and packaging. [`macos/README.md`](macos/README.md) covers each surface in depth |
| `crates/craft-backend` | API, poller, CLI integrations and SQLite stores |
| `crates/craft-ptyd` | The detached terminal daemon |
| `crates/craft-vt` | Headless Ghostty VT engine for terminal snapshots |
| `docs/` | [Data recovery](docs/DATA-RECOVERY.md) and images |

[`AGENTS.md`](AGENTS.md) is the fast path for making a change, and [`CLAUDE.md`](CLAUDE.md)
describes the app's architecture: layers, coordinators, and how a screen is added.

## Development

```bash
cargo test --manifest-path crates/craft-backend/Cargo.toml
cargo test --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots

xcodebuild test -project macos/Craft.xcodeproj -scheme Craft \
  -derivedDataPath macos/.build/xcode -only-testing:CraftTests
```

- Swift Testing ignores `-only-testing:` filters that name a single function: it runs
  nothing and still reports success. Read the `Executed N tests` line.
- A route exists in two places, `macos/Services/Backend/Routes.swift` and the Rust router.
  The `route_contract` test fails when they disagree.
- If `gh webhook` is not installed, polling still catches merges. `gh extension install
  cli/gh-webhook` makes updates arrive sooner.

## Packaging

Build the Release scheme, run `macos/scripts/bundle-backend.sh`, then
`macos/scripts/package-direct.py --local`. Craft is distributed as a direct download, not
through the App Store; [`macos/README.md`](macos/README.md) has the signing and notarization
steps. The backend binary also provides `backup`, `verify` and `restore` — see
[data recovery](docs/DATA-RECOVERY.md).

## Contributing

Contributions are welcome. Keep the snapshot rule in mind before changing how data moves:
handlers stay thin, and anything slow belongs in the poller or a service.

## License

ISC — see the `license` field in each crate's `Cargo.toml`.
