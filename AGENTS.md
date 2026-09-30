# AGENTS.md - working guide for Cascade

This is the shared working guide for contributors and coding agents, including the
native app's architecture. Read `README.md` for the product and setup, and
`macos/README.md` for deeper notes on individual surfaces.

## What this is

A native macOS app that tracks GitHub PRs, GitHub issues and Jira tickets per project, shows CI status,
runs agent sessions in worktrees, and auto-transitions Jira tickets when a PR merges.

The app and backend have two main languages:

- **Swift** (`macos/`) — SwiftUI + AppKit client: dashboard, Cocoa sidebar, Ghostty
  terminals, Sprint board, diff and editor surfaces, menu-bar tray.
- **Rust** (`crates/`) — the API, poller, CLI integrations and SQLite stores, linked
  **into the app** as a static library and called over a C ABI.

There is no Node or Tauri app host. The only bundled application JavaScript is two
network-less pages, the working-changes diff (`macos/Resources/DiffPage/`) and the agent
chat (`macos/Resources/ChatPage/`, built from `macos/web/chat/`); WebKit also hosts
remote context pages. GitHub uses `gh`, Git uses `git`, and most Jira operations use
`acli`. Optional Jira REST features, including board columns and Fix Versions, use
`jira_api_token` from settings. Build tooling and terminal bridges also use shell,
Python, and C.

## The one mental model that matters

**Stale-while-revalidate over a DB snapshot.**

- `crates/cascade-backend/src/poller.rs` **owns background GitHub synchronization**. Every
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

**Open `macos/Cascade.xcodeproj` and press ⌘R. That is the whole workflow.**

The app targets macOS 14+ on Apple Silicon. Building the current source requires
Xcode 26+ for its macOS 26 SDK APIs. The Rust backend requires Rust 1.88+.

The shared scheme's build pre-action runs `macos/scripts/bootstrap.sh`, which is
idempotent and does everything else: installs rustup into `~/.cargo` if missing,
downloads the pinned Ghostty VT runtime, and `cargo build --release`s the backend and the
PTY helper. Its log is `macos/.build/bootstrap.log`.

```bash
# Rust alone, without Xcode
cargo build   --manifest-path crates/cascade-backend/Cargo.toml
cargo test    --manifest-path crates/cascade-backend/Cargo.toml
cargo build   --manifest-path crates/cascade-ptyd/Cargo.toml --features terminal-snapshots

# Native app unit tests (the shared plan also includes CascadeUITests)
xcodebuild test -project macos/Cascade.xcodeproj -scheme Cascade \
  -derivedDataPath macos/.build/xcode -only-testing:CascadeTests
```

- **Swift Testing does not match `-only-testing:CascadeTests/someFunctionName`.** It runs
  **zero** tests and still reports `TEST SUCCEEDED`. Always check the `Executed N tests`
  line before believing a pass.
- The app links the backend as a static library by default. `--backend-path <binary>` runs
  it as a child process instead, and `--backend-url <origin>` points at one you started
  yourself; both are useful for isolating whether a bug is in the FFI boundary.
- `CASCADE_DATA_DIR` overrides the data directory (default
  `~/Library/Application Support/Cascade`).

## Files

**Backend** (`crates/cascade-backend/src/`):

- `lib.rs` - the axum router (`build_app`) and `AppState`; `route_contract` asserts the
  Swift route constants against the routes actually served.
- `ffi.rs` - the C ABI the app links: start/stop/request plus the event callback.
- `routes.rs` - thin handlers; `local.rs` - git, worktrees, files, diffs, Xcode;
  `github.rs` - `gh` wrapper, `lean()`, PR classification; `issues.rs` - GitHub issues as
  tickets (`gh issue`), searched live for My Tickets and never snapshotted; `jira.rs` - `acli`;
  `poller.rs` - the sync engine and merge automation; `warmup.rs` - IDE warm-up;
  `integrations.rs` - webhook forwarders; `usage.rs` - agent usage; `recovery.rs` - packaged-start data checks.
- `db.rs` + `schema_durable.sql` / `schema_cache.sql` / `schema_logs.sql` - the three
  SQLite stores.

**Terminal** (`crates/cascade-ptyd`, `crates/cascade-vt`): a detached PTY daemon and the
headless Ghostty VT engine used for terminal snapshots. Shells can outlive an
unexpected app exit; explicit Quit and update restart stop them.

**App** (`macos/`): see the native architecture sections below. In short — `App/`
entry and lifetime, `Scenes/` view+view-model pairs, `Coordinators/` presentation
identity, `Container/` factories, `Services/` non-UI logic, `Components/` reusable widgets.

## Conventions / gotchas

- **One repo per project.** A project maps to one GitHub repo, optional Jira project key,
  workspace path, color and merge transition.
- **Schema is `CREATE TABLE IF NOT EXISTS`** in the three `schema_*.sql` files — no
  migration framework. `data.db` and `logs.db` are regenerable caches; **`cascade.db` is
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
- **A new worktree is warmed up, not built cold.** `warmup.rs` prepares the checkout the IDE
  is about to open — for Xcode, `xcodebuild -resolvePackageDependencies`, which a fresh worktree
  would otherwise pay for inside the first build with a silent log. It is lazy: only the session
  being opened is warmed, coalesced per worktree, reporting through `ide-warmup` events that the
  build title turns a spinner for. Creating a session selects it, so a new one is warmed too. The module is IDE-neutral: each IDE contributes a `Plan` from
  its own module, and an IDE with no plan reports `ready`. It is background and non-fatal — a
  failed warm-up never blocks a session.
- **Worktree creation never touches the network.** It adds from what the checkout has and
  only fetches when adopting a branch that is not local yet — a fetch on the create path
  cannot succeed and once froze New Session for a minute. The one opt-in exception is
  Settings → Worktrees → "Always fetch before creating worktrees" (`worktree_fetch`, off by
  default): it fetches only the base branch, capped at 8 seconds, and falls back to the local
  ref (`worktrees.rs` `fetch_base`).
- **Child processes get their own process group** (`cli.rs`). The backend runs inside the
  app, so a child left in the app's group can take the app down with it, and a timeout
  kills the whole group rather than leaving a helper holding the output pipe.
- **Installed agent hooks keep themselves current.** At startup the backend brings up to date the
  hooks a person installed (`integrations::ensure_hooks`); it never installs hooks nobody
  installed, and removing them in Settings takes them out for good. Each hook reports to the app
  that started its terminal (`CASCADE_PORT_FILE`, set by `cascade-ptyd`), so a development build
  and the installed app can run side by side.
- **`acli` flags**: `workitem transition --key K --status S --yes`; use `--json` for reads.
- **`gh webhook` extension may be missing.** Polling still catches merges. Install it with
  `gh extension install cli/gh-webhook`.
- **Build is arm64-only**, ad-hoc signed for local use.
- Tray status icon: always **black/white** (the menu bar's own, a template glyph), with no review
  marker; pending reviews show in its tooltip and menu. `contentTintColor` on a status item comes
  out black under the menu bar's vibrancy, so any tint would have to be painted into the image.
- **A session is one task record per worktree** — the agent running on a worktree, live or
  stopped, linked to its context and titled by the page it was started from. A git worktree
  with no session is invisible to the app.
- **CLI differences live in the agent adapters and drivers, nowhere else.** In the backend each
  CLI implements `AgentProbe` (`crates/cascade-backend/src/agents/`: its profile, hooks, tools,
  commands, usage, transcript), and `Agent::of(cli)` is the one place that tells them apart by
  name. In the app each is an `AgentDriver` (`Services/Agents/AgentDriver.swift`: launch, model
  switching, names, glyphs, colour), and `AgentDrivers.of(cli)` is the one place. The chat goes by
  the `AgentProfile` the backend reports, and draws a tool call by its `kind` and the agent's
  `activity`. Nothing else compares a CLI's name. A new CLI is one adapter and one driver; tests
  fail until `SessionAgent`, `ManagedCLI` and the backend's registry all name it.
- **Views present what the API returns.** No view computes `gh`/`acli`-shaped logic or
  reaches for a CLI; that belongs in the backend.
- **Theme tokens only** (`Theme/`). The dark theme is a palette swap, never per-widget
  colors. File-type icons are the one exception: they keep their own colours.
- **Icons are vector assets**, never emoji.
- **A file is drawn through the chosen icon theme.** People install VS Code icon themes in
  Settings → Text Editor → File Icons by pasting a VS Code Marketplace or Open VSX link. The
  app ships one, vscode-icons (`Resources/DefaultIconTheme.vsix`, from
  `macos/scripts/vendor-default-icon-theme.py`; its ID is `IconThemeLibrary.bundledTheme`):
  installed on first launch and used until someone chooses otherwise, it is removed like any
  other and stays removed. Packages are downloaded from Open VSX only: Marketplace extensions may be
  installed only in Microsoft's products, so a Marketplace link just names the extension.
  `IconThemeLibrary` unpacks each into `<data>/IconThemes/<publisher.name>/` with its own
  reader (`ZipArchive`), which writes no link, nothing outside the package's folder and
  nothing past the size the package declares; `FileIconStore.shared` holds the one the
  `fileIconTheme` setting names. Draw with `FileIcon` in SwiftUI, passing the symbol the place
  shows without a theme, or `FileIconStore.shared.image(forFile:light:)` where AppKit draws.
  `FileIconTheme` picks an icon as VS Code does — whole name, longest extension, language,
  then the default — asking the theme's light variants first in a light appearance. Themes
  key most languages by language ID, which comes from VS Code, not the theme: the app ships
  that table (`Resources/VSCodeLanguages.bundle`), generated by
  `macos/scripts/vendor-vscode-languages.py <vscode-checkout>`; rerun it rather than editing.
- **Cascade Remote mirrors the chat through iCloud, from the app.** `Services/Remote/RemoteMirror`
  copies each live session's chat into the user's CloudKit private database and carries out what
  an iPhone sends back (a message typed through `RemoteDelivery`, an approval answered), but only
  a command signed by a phone approved on this Mac in Settings → iPhone: anything on the Apple
  Account can write one. `RemoteDelivery` is the one way a message is typed for someone who
  cannot see the terminal; never type for the phone around it.
  The mirror is the one place the app talks to CloudKit, off unless turned on in Settings →
  iPhone, and inert in a build without the iCloud entitlement (`macos/Signing.local.xcconfig`,
  opt-in). Its state lives in the data directory, not `UserDefaults`, so a run with its own data
  folder is its own mirror. The backend stays Apple-free and is still the source of truth
  (`/api/agent/transcript`).
  `Services/Remote/Shared/` is the wire format: the `cascade-ios` repository compiles a copy, so
  change both together. See `docs/remote/06-chat-mirror.md`.
- Project IDs are UUIDs.

## CLI tools available in this environment

`gh` (GitHub), `acli` (Atlassian/Jira), `cargo`/`rustup`, `xcodebuild`.

## Native app architecture

The app is SwiftUI + AppKit over a Rust backend linked into the same process.
Remote context pages use WebKit. **There are two bundled app pages**, each HTML + JS in a
`WKWebView`, and they share one shape: push-only, native code hands the page its whole state
through one `render` call; no network access (CSP `connect-src 'none'`); served on a scheme
of its own; and reports back through one message handler.

- **Working-changes diff** (`macos/Resources/DiffPage/`, hand-written). `DiffViewModel` loads
  the snapshot through `APIClient` and hands it to `window.nativeDiff.render`;
  `DiffPageAssets` serves it on `cascade-diff://`; it reports `ready`/`files`/`open`/`discard`, and
  `window.nativeDiff.reveal` scrolls it to a file of the changed-files list beside it.
- **Agent chat** (`macos/Resources/ChatPage/`, built). `TranscriptChatPage` replaces the
  whole conversation (`ChatPageState`) through `window.nativeChat.render` on every push;
  `ChatPageAssets` serves it on `cascade-chat://`; it reports
  `ready`/`copy`/`open`/`download`/`permission`/`error`. Its source is the React app in
  `macos/web/chat/`, and the app ships only the built files: run `npm run build` there after
  changing it, and commit the output.

Do not add a third page, and do not give either page a way to reach the backend.

## The layers, and who owns what

`macos/` is a layered tree. Each layer may depend on the ones below it, never above:

- **`App/`** — the process. `CascadeApp.swift` is the entry point; `AppDelegate.swift`
  owns `AppViewModel`, the app lifetime and the main window (`MainWindowController`). `AppViewModel` is split by area into
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
  `Terminal/`, `Agents/`, `App/`, `Jira/`, `Projects/`, `Settings/`, `Notifications/`, `Tray/`,
  `Remote/`.
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
   the screen should be addressable. Its toolbar is a branch of `Destination.windowToolbar`.

## The main window

The main window is AppKit's, not a SwiftUI scene, so its toolbar can be split where its
columns are, as Xcode's is. `MainWindowController` owns the window; its content is
`MainSplitViewController`: the sidebar, the screen (`AppCoordinatorView`), and the shown
workspace's context pane as the inspector column. AppKit holds each column to its minimum
width. The pane column follows `SessionWorkspaceViewModel.showsInspector`, and a pane the
user collapses from the divider is told back to the workspace.

- **The toolbar is described, not declared.** Screens do not use SwiftUI `.toolbar` in the
  main window. Each destination returns a `WindowToolbar` (`Destination.windowToolbar`,
  `SessionWorkspaceToolbar`) of items built from its models — leading, centre, trailing, and
  the pane's section; the sidebar's section is its toggle alone, against the divider, on every screen — and `MainToolbarController` draws it as `NSToolbarItem`s hosting the
  SwiftUI content, split by the sidebar and inspector tracking separators. It reads the
  description under observation, so what it reads redraws the toolbar.
- **The pane draws its own bar, in the title-bar zone.** The pane column runs the window's
  full height, as Xcode's inspector does, and each pane draws its compact tab bar in the zone
  AppKit reports as the safe area (`SessionWorkspacePane`, `CompactTabBarPlacement.titleBar`).
  The toolbar's pane section is the toggle alone, so showing or hiding the pane changes no
  toolbar item: the tracking separator carries the screen's trailing items along with the
  divider, and the bar slides with its column. Putting the bar in the toolbar instead broke
  that — a changed item set is re-laid out on the toolbar's own animation, not the divider's,
  and a hidden item keeps its width. The one bar that is a toolbar item is a page-only sidebar
  tab's (`CompactTabBarPlacement.toolbar`); it cannot hang its suggestions under itself, since
  a toolbar item clips what it draws outside, so the bar keeps its editing state and highlight
  on the models and the page beneath draws the list.
- Settings is the app's only SwiftUI scene. SwiftUI opens an app's first window scene at
  every launch but leaves a lone `Settings` shut, so any other window — Help included
  (`AppDelegate.showHelp`) — is AppKit's.

**Retired is terminal.** When a coordinator retires a model, that model must refuse every
entry point afterwards — a retired model that can be reactivated goes back on refresh
timers and fires callbacks for a screen that no longer exists. Guard every public method
with `!retired`, including the ones that only set appearance or visibility.

## Talking to the backend

- **`Services/Backend/APIClient.swift`** is the only way to reach the backend. Route paths
  come from `Routes.swift` — never string literals.
- **`Routes.swift` is hand-maintained**, and `route_contract` in
  `crates/cascade-backend/src/lib.rs` fails the build if it names a path the router does
  not serve. Add the route in both places.
- **Two transports, one interface.** By default the backend is a static library in this
  process and requests dispatch straight into the axum router over the C ABI
  (`EmbeddedBackend.swift` → `crates/cascade-backend/src/ffi.rs`). With `--backend-path`
  or `--backend-url` the same `APIClient` talks HTTP to a separate process. Code above the
  transport cannot tell the difference, and must not try to.
- **Events**: embedded mode delivers them directly; process mode subscribes over SSE
  (`SSEClient.swift`). `BackendRuntime.swift` picks between them.
- The embedded backend still opens an ephemeral loopback port, written to `.server-port`,
  for webhook forwarders and agent hooks.

## The terminal stack

Three pieces, deliberately separate:

- **`crates/cascade-ptyd`** — a detached daemon that owns the PTYs. It has its own session,
  so shells can survive an unexpected app exit. Closing the main window keeps sessions
  running; explicit Quit and update restart stop the daemon and shells through
  `AppViewModel.prepareToTerminate`. The app talks to it over a Unix socket
  (`Services/Terminal/PtydClient.swift`, launched by `PtydHost.swift`).
- **GhosttyTerminal** — a prebuilt XCFramework from
  `github.com/alexcding/ghostty-terminal-spm`, pinned to an exact tag in the pbxproj. This
  is the on-screen rendering surface.
- **`crates/cascade-vt`** — the headless Ghostty VT engine, used for terminal snapshots.
  Its `build.rs` asserts that the daemon and the renderer were built from the same patched
  Ghostty, because a snapshot written by one is read by the other.

`macos/patches/ghostty/*.patch` are the Ghostty source patches both sides build against.
When they change, cut a new tag in the package repo and bump it in **both** the pbxproj
and `macos/scripts/bootstrap.sh` — they must agree.

## Tests

- **`macos/Tests/`** is the `CascadeTests` target and `macos/UITests/` is
  `CascadeUITests`; the shared test plan runs both. `GhosttySnapshotTests/` is a separate
  SPM package and is not in the plan.
- Rust: `cargo test --manifest-path crates/cascade-backend/Cargo.toml`. `route_contract`
  keeps `Routes.swift` honest; `cli.rs`'s tests cover process-group teardown.
- After bootstrap has prepared Ghostty, run terminal tests with
  `cargo test --manifest-path crates/cascade-ptyd/Cargo.toml --features terminal-snapshots`.
- Substitute a `Container/` factory rather than reaching for the real backend, terminal or
  file system.
