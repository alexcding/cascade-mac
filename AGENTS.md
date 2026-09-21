# AGENTS.md - working guide for Craft

This is the shared working guide for contributors and coding agents, including the
native app's architecture. Read `README.md` for the product and setup, and
`macos/README.md` for deeper notes on individual surfaces.

## What this is

A native macOS app that tracks GitHub PRs and Jira tickets per project, shows CI status,
runs agent sessions in worktrees, and auto-transitions Jira tickets when a PR merges.

The app and backend have two main languages:

- **Swift** (`macos/`) — SwiftUI + AppKit client: dashboard, Cocoa sidebar, Ghostty
  terminals, Sprint board, diff and editor surfaces, menu-bar tray.
- **Rust** (`crates/`) — the API, poller, CLI integrations and SQLite stores, linked
  **into the app** as a static library and called over a C ABI.

There is no Node or Tauri app host. The only bundled application JavaScript is the
network-less working-changes diff page (`macos/Resources/DiffPage/`); WebKit also hosts
remote context pages. GitHub uses `gh`, Git uses `git`, and most Jira operations use
`acli`. Optional Jira REST features, including board columns and Fix Versions, use
`jira_api_token` from settings. Build tooling and terminal bridges also use shell,
Python, and C.

## The one mental model that matters

**Stale-while-revalidate over a DB snapshot.**

- `crates/craft-backend/src/poller.rs` **owns background GitHub synchronization**. Every
  poll interval it fetches each project's PRs by status — every open PR (paginated, with
  CI) plus a recent merged/closed window for merge detection — and writes a **lean
  snapshot** (`github.rs:324 lean()`) to `data.db`. Concurrent syncs of one project are
  coalesced, so a stale read racing the poll loop cannot double-spawn `gh`.
- Snapshot API endpoints **read the snapshot** (instant). A stale read triggers a background
  sync. Never add a `gh` call to a request handler.
- Snapshot changes broadcast a `sync` event. In the default embedded mode the backend
  hands events straight to the app; against a separate backend process the app subscribes
  over SSE (`macos/Services/Backend/BackendRuntime.swift`).

If the UI needs fresher data, fix the sync loop. Do not make endpoints call `gh`.

## Run / iterate

**Open `macos/Craft.xcodeproj` and press ⌘R. That is the whole workflow.**

The app targets macOS 14+ on Apple Silicon. Building the current source requires
Xcode 26+ for its macOS 26 SDK APIs. The Rust backend requires Rust 1.88+.

The shared scheme's build pre-action runs `macos/scripts/bootstrap.sh`, which is
idempotent and does everything else: installs rustup into `~/.cargo` if missing,
downloads the pinned Ghostty VT runtime, and `cargo build --release`s the backend and the
PTY helper. Its log is `macos/.build/bootstrap.log`.

```bash
# Rust alone, without Xcode
cargo build   --manifest-path crates/craft-backend/Cargo.toml
cargo test    --manifest-path crates/craft-backend/Cargo.toml
cargo build   --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots

# Native app unit tests (the shared plan also includes CraftUITests)
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

**Terminal** (`crates/craft-ptyd`, `crates/craft-vt`): a detached PTY daemon and the
headless Ghostty VT engine used for terminal snapshots. Shells can outlive an
unexpected app exit; explicit Quit and update restart stop them.

**App** (`macos/`): see the native architecture sections below. In short — `App/`
entry and lifetime, `Scenes/` view+view-model pairs, `Coordinators/` presentation
identity, `Container/` factories, `Services/` non-UI logic, `Components/` reusable widgets.

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
- **A session is one task record per worktree** — the agent running on a worktree, live or
  stopped, linked to its context and titled by the page it was started from. A git worktree
  with no session is invisible to the app.
- **Views present what the API returns.** No view computes `gh`/`acli`-shaped logic or
  reaches for a CLI; that belongs in the backend.
- **Theme tokens only** (`Theme/`). The dark theme is a palette swap, never per-widget
  colors.
- **Icons are vector assets**, never emoji.
- Project IDs are UUIDs.

## CLI tools available in this environment

`gh` (GitHub), `acli` (Atlassian/Jira), `cargo`/`rustup`, `xcodebuild`.

## Native app architecture

The app is SwiftUI + AppKit over a Rust backend linked into the same process.
Remote context pages use WebKit. **The one bundled app page is the working-changes
diff**: HTML + JS (`macos/Resources/DiffPage/`) in a `WKWebView`.
It is push-only: `DiffViewModel` loads the snapshot through `APIClient` and
hands it to `window.nativeDiff.render`; the page has no network access (CSP
`connect-src 'none'`), is served by `DiffPageAssets` on its own `craft-diff://` scheme,
and reports `ready`/`open`/`discard` back through one message handler. Do not add a second
page, and do not give this one a way to reach the backend.

## The layers, and who owns what

`macos/` is a layered tree. Each layer may depend on the ones below it, never above:

- **`App/`** — the process. `CraftApp.swift` is the entry point; `AppDelegate.swift`
  owns `AppViewModel` and the app lifetime. `AppViewModel` is split by area into
  `AppViewModel+{Root,Workspace,Settings,Tray,Notifications}.swift`; `RootViewModel.swift`
  is what the root view binds to.
- **`Scenes/`** — one folder per area (`Dashboard`, `Projects`, `Jira`, `Documents`,
  `Activity`, `Settings`, `Welcome`, `Workspace`), each a view plus an
  `@MainActor @Observable` view model. A view model exposes an `Action` enum and an
  `onAction` closure; it never reaches
  for a coordinator or the app. `Settings` is the one area that is not a sidebar selection:
  it is its own SwiftUI `Settings` scene window (`SettingsWindowView`), and its coordinator
  follows `AppCoordinator.settingsPresented` instead of `selection`. `Activity` lives inside
  it as a section: `LogsCoordinator` follows `AppCoordinator.activityVisible`, and
  `presentActivity()` is how the bell popover and notification clicks get there.
- **`Coordinators/`** — presentation identity and model lifetime. A coordinator decides
  which model is current for a screen, whether it may present, and when it retires.
  `Coordinators/App/AppCoordinator.swift` is the root; routing and deep links live in
  `AppCoordinator+Routing.swift`.
- **`Container/`** — the factories that build models, one protocol per feature
  (`RootFeatureFactory`, `WorkspaceFeatureFactory`, `ProjectFeatureFactory`,
  `DocumentFeatureFactory`, `BackendFeatureFactory`, `CreationFlowFactory`,
  `AppPlatformFactory`, `WelcomeFeatureFactory`). Tests substitute these; production
  uses the `Native*` versions.
- **`Services/`** — everything that is not a view, by domain: `Backend/`, `Workspace/`,
  `Terminal/`, `Agents/`, `App/`, `Jira/`, `Projects/`, `Settings/`, `Notifications/`, `Tray/`.
- **`Components/`** — reusable widgets with no screen of their own (`Sidebar/`,
  `Terminal/`, `Tray/`, `Sheet/`, `Notifications/`).
- **`Theme/`** tokens and fonts, **`Utilities/`** deep links, **`Resources/`** assets,
  xcconfigs and the provider artwork the toolbar draws.

## Adding a screen

A screen is four things, in this order:

1. **`Scenes/<Area>/<Area>View.swift` + `<Area>ViewModel.swift`** — the view model is
   `@MainActor @Observable`, owns its own loading and error state, and reports out through
   `Action`/`onAction` rather than calling into the app.
2. **`Coordinators/<Area>/<Area>Coordinator.swift`** — a `<Area>FeatureFactory` protocol
   plus its `Native` implementation, and the coordinator itself: `model`, `retired`,
   `isOwned`, `canPresent`, `handle`, `retire`. `Coordinators/Dashboard/DashboardCoordinator.swift`
   is the smallest complete example.
3. **Registration** — `extension AppCoordinator { install<Area>; make<Area> }`. `install`
   gates on the current `selection` and stores the coordinator on an `AppCoordinator`
   property.
4. **Navigation** — a `SidebarDestination` case (`Components/Sidebar/SidebarModel.swift`),
   a branch wherever selection is switched (`Coordinators/Abstractions/Destination.swift`,
   `AppCoordinator.navigate`), and a deep-link route in `AppCoordinator+Routing.swift` if
   the screen should be addressable.

**Retired is terminal.** When a coordinator retires a model, that model must refuse every
entry point afterwards — a retired model that can be reactivated goes back on refresh
timers and fires callbacks for a screen that no longer exists. Guard every public method
with `!retired`, including the ones that only set appearance or visibility.

## Talking to the backend

- **`Services/Backend/APIClient.swift`** is the only way to reach the backend. Route paths
  come from `Routes.swift` — never string literals.
- **`Routes.swift` is hand-maintained**, and `route_contract` in
  `crates/craft-backend/src/lib.rs` fails the build if it names a path the router does
  not serve. Add the route in both places.
- **Two transports, one interface.** By default the backend is a static library in this
  process and requests dispatch straight into the axum router over the C ABI
  (`EmbeddedBackend.swift` → `crates/craft-backend/src/ffi.rs`). With `--backend-path`
  or `--backend-url` the same `APIClient` talks HTTP to a separate process. Code above the
  transport cannot tell the difference, and must not try to.
- **Events**: embedded mode delivers them directly; process mode subscribes over SSE
  (`SSEClient.swift`). `BackendRuntime.swift` picks between them.
- The embedded backend still opens an ephemeral loopback port, written to `.server-port`,
  for webhook forwarders and agent hooks.

## The terminal stack

Three pieces, deliberately separate:

- **`crates/craft-ptyd`** — a detached daemon that owns the PTYs. It has its own session,
  so shells can survive an unexpected app exit. Closing the main window keeps sessions
  running; explicit Quit and update restart stop the daemon and shells through
  `AppViewModel.prepareToTerminate`. The app talks to it over a Unix socket
  (`Services/Terminal/PtydClient.swift`, launched by `PtydHost.swift`).
- **GhosttyTerminal** — a prebuilt XCFramework from
  `github.com/alexcding/ghostty-terminal-spm`, pinned to an exact tag in the pbxproj. This
  is the on-screen rendering surface.
- **`crates/craft-vt`** — the headless Ghostty VT engine, used for terminal snapshots.
  Its `build.rs` asserts that the daemon and the renderer were built from the same patched
  Ghostty, because a snapshot written by one is read by the other.

`macos/patches/ghostty/*.patch` are the Ghostty source patches both sides build against.
When they change, cut a new tag in the package repo and bump it in **both** the pbxproj
and `macos/scripts/bootstrap.sh` — they must agree.

## Tests

- **`macos/Tests/`** is the `CraftTests` target and `macos/UITests/` is
  `CraftUITests`; the shared test plan runs both. `GhosttySnapshotTests/` is a separate
  SPM package and is not in the plan.
- Rust: `cargo test --manifest-path crates/craft-backend/Cargo.toml`. `route_contract`
  keeps `Routes.swift` honest; `cli.rs`'s tests cover process-group teardown.
- After bootstrap has prepared Ghostty, run terminal tests with
  `cargo test --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots`.
- Substitute a `Container/` factory rather than reaching for the real backend, terminal or
  file system.
