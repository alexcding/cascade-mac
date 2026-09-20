# AGENTS.md - working guide for Craft

Read `README.md` for the full picture, `CLAUDE.md` for the native app's architecture,
and `macos/README.md` for the depth on any single surface. This file is the fast path
for making changes.

## What this is

A native macOS app that tracks GitHub PRs and Jira tickets per project, shows CI status,
runs agent sessions in worktrees, and auto-transitions Jira tickets when a PR merges.

Two languages, no others:

- **Swift** (`macos/`) — SwiftUI + AppKit client: dashboard, Cocoa sidebar, Ghostty
  terminals, Sprint board, diff and editor surfaces, menu-bar tray.
- **Rust** (`crates/`) — the API, poller, CLI integrations and SQLite stores, linked
  **into the app** as a static library and called over a C ABI.

There is no Node, no web renderer and no Tauri host. The only JavaScript is the bundled,
network-less working-changes diff page (`macos/Resources/DiffPage/`, see `CLAUDE.md`). Data comes from the
`gh` and `acli` CLIs and from `git` — no API tokens of Craft's own.

## The one mental model that matters

**Stale-while-revalidate over a DB snapshot.**

- `crates/craft-backend/src/poller.rs` is the **only** thing that calls `gh`. Every
  poll interval it fetches each project's PRs by status — every open PR (paginated, with
  CI) plus a recent merged/closed window for merge detection — and writes a **lean
  snapshot** (`github.rs:324 lean()`) to `data.db`. Concurrent syncs of one project are
  coalesced, so a stale read racing the poll loop cannot double-spawn `gh`.
- Every API endpoint **reads the snapshot** (instant). A stale read triggers a background
  sync. Never add a `gh` call to a request handler.
- Snapshot changes broadcast a `sync` event. In the default embedded mode the backend
  hands events straight to the app; against a separate backend process the app subscribes
  over SSE (`macos/Services/Backend/BackendRuntime.swift`).

If the UI needs fresher data, fix the sync loop. Do not make endpoints call `gh`.

## Run / iterate

**Open `macos/Craft.xcodeproj` and press ⌘R. That is the whole workflow.**

The shared scheme's build pre-action runs `macos/scripts/bootstrap.sh`, which is
idempotent and does everything else: installs rustup into `~/.cargo` if missing,
downloads the pinned Ghostty VT runtime, and `cargo build --release`s the backend and the
PTY helper. Its log is `macos/.build/bootstrap.log`.

```bash
# Rust alone, without Xcode
cargo build   --manifest-path crates/craft-backend/Cargo.toml
cargo test    --manifest-path crates/craft-backend/Cargo.toml
cargo build   --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots

# The Swift suites (275 tests across CraftTests + CraftUITests)
xcodebuild test -project macos/Craft.xcodeproj -scheme Craft \
  -derivedDataPath macos/.build/xcode -only-testing:CraftTests
```

- **Swift Testing does not match `-only-testing:CraftTests/someFunctionName`.** It runs
  **zero** tests and still reports `TEST SUCCEEDED`. Always check the `Executed N tests`
  line before believing a pass.
- The app links the backend as a static library by default. `--backend-path <binary>` runs
  it as a child process instead, and `--backend-url <origin>` points at one you started
  yourself; both are useful for isolating whether a bug is in the FFI boundary.
- `CRAFT_DATA_DIR` overrides the data directory (default
  `~/Library/Application Support/Craft`).

## Files

**Backend** (`crates/craft-backend/src/`):
- `lib.rs` - the axum router (`build_app`) and `AppState`; `route_contract` asserts the
  Swift route constants against the routes actually served.
- `ffi.rs` - the C ABI the app links: start/stop/request plus the event callback.
- `routes.rs` - thin handlers; `local.rs` - git, worktrees, files, diffs, Xcode;
  `github.rs` - `gh` wrapper, `lean()`, PR classification; `jira.rs` - `acli`;
  `poller.rs` - the sync engine and merge automation; `integrations.rs` - webhook
  forwarders; `usage.rs` - agent usage; `recovery.rs` - packaged-start data checks.
- `db.rs` + `schema_durable.sql` / `schema_cache.sql` / `schema_logs.sql` - the three
  SQLite stores.

**Terminal** (`crates/craft-ptyd`, `crates/craft-vt`): a detached PTY daemon whose
shells outlive the app, and the headless Ghostty VT engine used for terminal snapshots.

**App** (`macos/`): see `CLAUDE.md`. In short — `App/` entry and lifetime, `Scenes/`
view+view-model pairs, `Coordinators/` presentation identity, `Container/` factories,
`Services/` non-UI logic, `Components/` reusable widgets.

## Conventions / gotchas

- **One repo per project.** A project maps to one GitHub repo, optional Jira JQL,
  workspace path, color and merge transition.
- **Schema is `CREATE TABLE IF NOT EXISTS`** in the three `schema_*.sql` files — no
  migration framework. `data.db` and `logs.db` are regenerable caches; **`craft.db` is
  not** — it holds projects, tasks, tabs and settings.
- **Two PR classifications, different surfaces — don't conflate them** (`github.rs`):
  - **`category`** (`mine`/`review`/`other`) — strictly "I am an *actively requested*
    reviewer". Drives the **tray and its sound**. Keep it narrow: broadening it re-fires
    review sounds. GitHub drops you from `reviewRequests` the moment you submit any
    review, so `category` flips to `other` then.
  - **`awaitingMyReview`** (`github.rs:313`) — broader "still in my review orbit":
    requested **or** I have left any review, non-draft, not mine. Drives the dashboard's
    Review section. Mirror it in any Mine-vs-Review split; never group on raw `category`.
- **The snapshot is lean** (`github.rs:324`): the app only ever sees fields `lean()` copies
  through. A new `gh` field must be added to both the PR query and `lean()`, or it is
  silently absent client-side.
- **Worktree creation never touches the network.** It adds from what the checkout has and
  only fetches when adopting a branch that is not local yet — a fetch on the create path
  cannot succeed and once froze New Session for a minute.
- **Child processes get their own process group** (`cli.rs`). The backend runs inside the
  app, so a child left in the app's group can take the app down with it, and a timeout
  kills the whole group rather than leaving a helper holding the output pipe.
- **`acli` flags**: `workitem transition --key K --status S --yes`; use `--json` for reads.
- **`gh webhook` extension may be missing.** Polling still catches merges. Install it with
  `gh extension install cli/gh-webhook`.
- **Build is arm64-only**, ad-hoc signed for local use.
- Tray status color: **black/white** idle, **blue** tasks, **bronze (#98712c)** review.

## CLI tools available in this environment

`gh` (GitHub), `acli` (Atlassian/Jira), `cargo`/`rustup`, `xcodebuild`.
