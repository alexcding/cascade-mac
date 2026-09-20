# CLAUDE.md — Craft

Read `AGENTS.md` first (what this is, the snapshot model, run/iterate, backend
conventions). `macos/README.md` is the long-form guide to individual surfaces. This file
documents the **native app's architecture**, which they cover only in passing.

The app is SwiftUI + AppKit over a Rust backend linked into the same process. There is no
web layer: no renderer, no Node, no page talking to the backend. **The one exception is the
working-changes diff**, which is a bundled HTML + JS page (`macos/Resources/DiffPage/`) in a
`WKWebView`. It is push-only: `DiffViewModel` loads the snapshot through `APIClient` and
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
  `Activity`, `Settings`, `Workspace`), each a view plus an `@MainActor @Observable` view
  model. A view model exposes an `Action` enum and an `onAction` closure; it never reaches
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
  `AppPlatformFactory`). Tests substitute these; production uses the `Native*` versions.
- **`Services/`** — everything that is not a view, by domain: `Backend/`, `Workspace/`,
  `Terminal/`, `Jira/`, `Projects/`, `Settings/`, `Notifications/`, `Tray/`.
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
   a branch wherever selection is switched (`RootViewModel.Destination`,
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
  so shells survive an app restart or crash. The app talks to it over a Unix socket
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

## Conventions

- **Mine vs Review splits follow `awaitingMyReview`, never raw `category`.** A PR you have
  only commented on is `category:'other'` but still belongs under Review. The tray and its
  sound are the deliberate exception and stay on `category` — see `AGENTS.md`.
- **A session is one task record per worktree** — the agent running on a worktree, live or
  stopped, linked to its context and titled by the page it was started from. A git worktree
  with no session is invisible to the app.
- **Views present what the API returns.** No view computes `gh`/`acli`-shaped logic or
  reaches for a CLI; that belongs in the backend.
- **Theme tokens only** (`Theme/`). The dark theme is a palette swap, never per-widget
  colors.
- **Icons are vector assets**, never emoji.
- Project IDs are UUIDs.

## Tests

- **`macos/Tests/`** is the `CraftTests` target (67 files) and `macos/UITests/` is
  `CraftUITests`; the shared test plan runs both. `GhosttySnapshotTests/` is a separate
  SPM package and is not in the plan.
- **Swift Testing ignores `-only-testing:CraftTests/someFunctionName`** — it runs zero
  tests and still prints `TEST SUCCEEDED`. Read the `Executed N tests` line, always.
- Rust: `cargo test --manifest-path crates/craft-backend/Cargo.toml`. `route_contract`
  keeps `Routes.swift` honest; `cli.rs`'s tests cover process-group teardown.
- Substitute a `Container/` factory rather than reaching for the real backend, terminal or
  file system.
