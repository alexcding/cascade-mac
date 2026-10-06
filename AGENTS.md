# AGENTS.md - working guide for Cascade

This is the shared working guide for contributors and coding agents, including the
native app's architecture. Read `README.md` for the product and setup,
`macos/README.md` for deeper notes on individual surfaces, and
`docs/BACKEND-ARCHITECTURE.md` for the layering the Rust backend is moving to.

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

- `crates/cascade-backend/src/poller.rs` **owns GitHub synchronization**. A sync fetches
  projects' PRs — every open PR (with CI) plus a recent merged/closed window for merge
  detection — for up to five repos in one GraphQL query (`github.rs` `fetch_repos`), and
  writes a **lean snapshot** (`github.rs` `lean()`) to `data.db`. The engine runs the same
  sync once at a time, so two stale reads cannot double-spawn `gh`.
- **Syncs are lazy.** Snapshot API endpoints **read the snapshot** (instant), and a read
  older than the poll interval, made for someone looking, triggers a background sync of what it
  showed: `/api/dashboard`
  and `/api/prs/tray` sync the stale projects, the board its own. The poll loop syncs only
  what an armed automation waits for: projects a PR pipeline covers, and Jira pipelines' JQL.
  A project nobody looks at and no automation watches costs no `gh` call. Never add a `gh`
  call to a request handler.
- **A read follows a look.** The backend keeps no timer for what is on screen; the app reads
  again what the main window shows while someone is looking at it
  (`Services/App/AttentionMonitor.swift` → `AppViewModel.attend`): when the app comes to the
  front, when the window comes back on screen, when the Mac wakes, and every poll interval for
  as long as the app stays frontmost with the window visible. The tray reads when it opens. An
  app in the background, a hidden window and a sleeping display read nothing. A new screen that
  shows a snapshot gets a branch in `attend`, not a timer of its own.
- **Only a look syncs, and the app says which reads are looks** (`?look=1`: `DashboardService.look`,
  `ShellDataServing.lookAtReviews`). The app reads the same snapshots for two reasons: someone
  looks at them, or the backend just reported a sync (`sync` event). The second is the echo of
  a sync, and must never start one: told apart by timing, a slow enough sync closes the loop
  and the app syncs for ever with nobody looking. So a read made in `refreshSnapshots` is plain,
  and a read made for a person (`attend`, `reload`, the tray, Retry) is a look. Looks are paced
  by the engine from when the last sync started (`poller.rs` `Ask::Stale`). My Tickets goes by
  the same rule with one more case (`TicketRead` → `kept::Read`): an echo reads what is stored,
  a look also lets the backend search again behind it, and Refresh searches now.
- Snapshot changes broadcast a `sync` event. In the default embedded mode the backend
  hands events straight to the app; against a separate backend process the app subscribes
  over SSE (`macos/Services/Backend/BackendRuntime.swift`).

If the UI needs fresher data, sync on its read or fix the sync. Do not make endpoints call `gh`.

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
- `routes.rs` - thin handlers; `local/` - files, IDE, worktrees, git and patches, one module each;
  `github.rs` - `gh` wrapper, `lean()`, PR classification; `issues.rs` - GitHub issues as
  tickets (`gh issue`), searched live except for My Tickets' own searches; `kept.rs` - the
  answers the backend keeps for My Tickets: given at once from the last one stored, searched
  again behind a look, searched now for a refresh someone asked for; `jira.rs` - `acli` and
  Jira REST: search, the active sprint, transitions, assignment, versions; `poller.rs` - the sync
  engine and merge automation; `warmup.rs` - IDE warm-up; `integrations.rs` - webhook forwarders
  and agent hooks; `settings_file.rs` - the CLIs' JSON settings files, read and written whole;
  `usage.rs` - the usage snapshot the app reads, probed per CLI in `agents/usage.rs`;
  `automation/` - pipelines: triggers, filters, actions, the runner and its routes;
  `recovery.rs` - packaged-start data checks. Modules depend one way: `routes`, `poller` and
  `automation` call the adapters (`github`, `jira`, `agents`, `integrations`), and an adapter
  never calls back up; what a handler needs from two of them (a transcript with its hook status,
  a forwarder fix) is joined in the handler.
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
  not** — it holds projects, tasks, links and the backend's config. Window state is the app's
  and never goes through the backend: preferences (theme, fonts, terminal, editor, board filters)
  in `UserDefaults`, each context's page tabs in `page-tabs.json` (`ViewerStore`).
  `GET /api/settings` stays read-only for one release so what an earlier version left in the
  backend is imported once.
- **The backend tells the app what changed through `Event`** (`crates/cascade-backend/src/event.rs`),
  sent with `AppState::publish`; its variant and field names are what the app's `ServerEvent`
  decodes. A snapshot equal to the one stored is not an event. The one untyped broadcast left is
  an agent hook relayed as it arrived.
- **SQLite runs on the stores' own threads.** Every `Database` method is `async` and hands a
  closure to its `db::Store`; nothing holds a connection, and no statement runs on a runtime
  worker. A sync function that needs the database becomes async, not the other way round.
- **Processes go through one seam.** `cli::run` and its siblings build a `cli::Invocation` and hand
  it to the `CommandRunner`: the process spawner in production, a `cli::ScriptedRunner` a test
  installs with `cli::scoped`; a task spawned on a test's behalf gets it through `cli::inherited`.
- **The sync engine is one task** (`poller.rs` `Engine`), and `AppState.poller` is its handle:
  every method is a message. It owns which syncs are running, each project's invalidation
  generation and the last state each pull request was seen in; a sync is a function it spawns,
  the same sync asked for while it runs is not started again, and GitHub syncs run four at a
  time (`poller::GH_LANES`), so a burst of `gh` never queues a request the user is waiting on.
  The webhook forwarders (`integrations.rs` `Forwarders`) and the tool approvals waiting on the
  app (`agents/permission.rs` `Permissions`) are the same shape: one task owns the state, and the
  `AppState` field is its handle. State with no loop and no children of its own (`Usage`,
  `Warmup`, `automation::Limits`) is a value on `AppState` behind a short lock, never held across
  an await. Nothing that depends on an `AppState` lives in a static.
- **A sync that fails says whose fault it is** (`domain::Fault`). A command's failure carries how
  it ended (`cli::Failure`: never started, timed out, exited), and each adapter reads the rest
  from what its CLI printed (`github::fault`, `jira::fault`). `Transient` is the service's: a
  timeout, the network, a 5xx, a rate limit. The snapshot stands, nothing goes to Activity, and
  the engine's breaker for that upstream (`poller.rs` `Breaker`) turns background syncs away for
  a wait that doubles with each failure in a row, 30 seconds up to 15 minutes; a refresh someone
  asked for still runs. The app hears one `upstream` event when GitHub or Jira stops answering
  and one when it is back, and `GET /api/upstreams` lists the ones failing. `Permanent` is the
  request's (a repository that is gone, a sign-in that lapsed): it is the project's error, told
  once, and that project is then fetched by itself so it does not fail the others' query. What
  is not recognised is permanent, so an unknown error is shown rather than waited out.
- **What happened while nobody looked is caught up on, not replayed.** A sync that follows a gap
  (three poll intervals and a minute, four minutes at least) logs the changes it finds as `quiet` activity
  and tells them once, in a `prs_caught_up` line that counts them (`poller.rs`
  `record_lifecycle`); a single change is told as itself. The app keeps a quiet line in Activity
  and raises no notice for it (`NotificationStore.receiveActivity`). Automations hear every merge
  either way.
- **Two PR classifications, different surfaces — don't conflate them** (`github.rs`):
  - **`category`** (`mine`/`review`/`other`) — strictly "I am an *actively requested*
    reviewer". Drives the **tray and its sound**. Keep it narrow: broadening it re-fires
    review sounds. GitHub drops you from `reviewRequests` the moment you submit any
    review, so `category` flips to `other` then.
  - **`awaitingMyReview`** (`github.rs` `enrich`) — broader "still in my review orbit":
    requested **or** I have left any review, non-draft, not mine. Drives the dashboard's
    Review section. Mirror it in any Mine-vs-Review split; never group on raw `category`.
- **The snapshot is lean** (`github.rs` `lean()`): the app only ever sees fields `lean()` copies
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
- **Run launches what the scheme launches.** `xcodebuild` only builds, so the launch is Cascade's:
  it passes the enabled arguments and environment of the scheme's launch action, read from the
  scheme file (`xcode.rs` `launch_of`), on a Mac, a simulator and a device. Cascade's own scheme
  names the data folder a development build runs on; without it the build finds the installed
  app holding the default folder and yields. The scheme's launch pre-actions are not run.
- **A copy of Cascade that runs its own scheme is asked to leave, not ended.** Run ends the app's
  running copy before it launches the new build (`pkill`), but a debugger holds the copy it is
  attached to against every signal, SIGKILL included, and the new build then yields to it. So the
  chain asks through `/api/hooks/relaunch`, the copy leaves by itself as Quit does, asking about
  unsaved files, but keeps the daemon the chain runs in (`AppViewModel.leaveForRelaunch`), and
  the new build is opened outside the terminal with `open -n`. A copy that cannot hear the ask is
  ended as any other app is.
- **`acli` flags**: `workitem transition --key K --status S --yes`; use `--json` for reads.
- **`gh webhook` extension may be missing.** Then nothing is pushed: pull requests refresh
  behind a look, and the automations' loop still catches merges. Install it with
  `gh extension install cli/gh-webhook`.
- **A forwarded pull request event refreshes its project.** Every project that forwards
  (`automation::forward_repos`: forwarding on, the project's own switch on, a repo) runs a
  `gh webhook forward`, pipeline or none, and every `pull_request` event it delivers
  (`integrations.rs` `github_webhook`) tells the engine the project changed (`Poller::changed`).
  That is how a snapshot is kept up with nobody looking at it, and it is held in: events are
  gathered for two seconds so a burst is one batched query, a project is not synced again
  within the poll interval of its last sync (one sync at the end of the gap covers what came
  during it), and nothing is synced on an event's word while GitHub is failing or under a
  fifth of the hour's rate allowance is left (`poller.rs` `Budget`, read from each batched
  query's `rateLimit`; it holds events only, never a look or an automation's poll). An event
  is not lost to an outage: a project its sync could not reach GitHub for waits again, and is
  synced when GitHub answers. A merge is still told at once, for the pipelines that act on one.
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
  The one exception is a file tree (`FileTreePanel`: the worktree's files and the diff's changed
  files, and the breadcrumb's folder card beside them, `WorktreeFolderMenu`): its rows are drawn
  as Finder draws them, with the system's folder and each type's own icon (`SystemFileIcon`), as a
  Git client's trees are.
- Project IDs are UUIDs.

## CLI tools available in this environment

`gh` (GitHub), `acli` (Atlassian/Jira), `cargo`/`rustup`, `xcodebuild`.

## Native app architecture

The app is SwiftUI + AppKit over a Rust backend linked into the same process.
Remote context pages use WebKit. **There are two bundled app pages**, each HTML + JS in a
`WKWebView`. Both have no network access (CSP `connect-src 'none'`), are served on a scheme of
their own, and report back through one message handler.

- **Working-changes diff** (`macos/Resources/DiffPage/`, hand-written). Push-only:
  `DiffViewModel` loads the snapshot through `APIClient` and hands it to
  `window.nativeDiff.render`; `DiffPageAssets` serves it on `cascade-diff://`; it reports
  `ready`/`files`/`open`/`discard`, and `window.nativeDiff.reveal` scrolls it to a file of the
  changed-files list beside it.
- **Agent chat** (`macos/Resources/ChatPage/`, built). Synara's own web client
  (`macos/web/chat/`, its files vendored verbatim under `vendor/synara` and never edited; see
  `macos/web/chat/SYNARA.md`). It asks native for what it needs and is pushed the rest: requests
  (`{kind:"request", method, params}`) are answered through `window.nativeChat.reply`, and
  `window.nativeChat.push` delivers the `context`, `providers` and `thread` channels, plus
  `files`, what Finder files picked, dropped or pasted in add to the composer: a drop or paste of
  Finder files is the app's whole (WebKit never delivers it), an image the agents take (PNG, JPEG,
  GIF, WebP) is read and sent to be uploaded, any other file or folder becomes an `@path` mention.
  `ChatPageModel` hosts it, `ChatPageAssets` serves it on `cascade-chat://`, and a
  `ChatPageBackend` answers it: the chat RPC for a chat session, the terminal transcript (read
  only) for a terminal session. Only native reaches the backend; the page never does. The app
  ships only the built files: run `npm run build` there after changing it, and commit the output.

Do not add a third page, and do not give either page a way to reach the backend.

## Chat sessions

A chat is an agent CLI driven headlessly over its JSON protocol: `claude` over stream-json,
`codex app-server` over JSON-RPC. The engine is `crates/cascade-chat`, a port of Synara's
provider layer kept file for file like its TypeScript (`crates/cascade-chat/SYNARA.md` maps
each file and pins the upstream commit). It owns `chat.db` under `<data>/chat` and starts its
CLIs through the backend's process seam (`chat.rs` `CliSpawner`: login PATH, own process
group, no terminal hook variables). The backend serves it on one route, `POST /api/chat/rpc`
(`chat.rs`), and tells the app what changed as `chat-thread`/`chat-shell`/`chat-removed`
events. A chat belongs to a project (it works in the project's folder) or to none
(`cascade-standalone`, in a folder the person picked); either way it is a thread in `chat.db`,
not a task record, and has no worktree of its own. A subagent the agent runs (Claude's Task tool,
a Codex child conversation) gets a thread of its own, `subagent:<parent>:<id>`, whose shell names
its `parentThreadId`: lists leave it out (`ChatListStore.visible`), the parent's page opens it, and
it shows read-only. To take Synara's newer code, re-vendor the page and port the mapped Rust
files' upstream diffs by hand.

A session's pane has Chat tabs too (`PaneChatModel`, `PaneChatView`): each starts a chat from its
own new-chat form (`PaneNewChatForm`), a regular chat with a history of its own that works in the
session's worktree and is tagged with it (`worktreePath`), which keeps it, and the forks made from
it, out of the lists (`ChatListStore.visible`); it is reached from its tab, and once its tab is
closed from any Chat tab's form, which lists the worktree's chats no tab shows
(`ChatListStore.inWorktree`) and opens one in its tab. That form alone offers
"Include what the session's agent knows", off by default and disabled with its reason when the
session runs no agent or the app knows no conversation of it (`chat.sessionKnowledge`). Turned on,
`thread.create` carries Cascade's `knowledgeSource` (`{provider, conversationId}`, the session's
agent and conversation): the backend takes it only for a session's worktree, for that exact
conversation held there (Claude's transcript in the worktree's own project folder, Codex's session
file whose `session_meta` names that id and worktree) and held by no chat — never the worktree's
newest — and reads its transcript (`chat/knowledge.rs`). The engine keeps it until a turn of the
chat completes — the same provider forks the conversation natively (Claude `--resume
--fork-session`, Codex `thread/fork`), another gets Synara's handoff recap of the transcript as
hidden context — and takes it again if the chat's conversation is reset before that.
A chat's revert and edit take back only its own turns' changes, never the whole folder the
terminal agent or the person also works in (`crates/cascade-chat/SYNARA.md`). The chat
shows none of the session's messages, only one `provider.handoff` divider saying it started with
that agent's knowledge, and the terminal session and its conversation are not touched. A Claude
fork takes the transcript as it stands on disk, so a turn the terminal is still in is cut where
it was written.

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
- **The pane draws its own bar, under the toolbar.** The pane column runs the window's full height,
  as Xcode's inspector does, and draws its tab strip (`BrowserCompactTabBar.Part.tabs`,
  `CompactTabBarPlacement.titleBar`) in its title-bar zone, which AppKit reports as the safe area.
  The strip is part of the column, so it slides with it: showing or hiding the pane changes no
  toolbar item, and the toolbar's items keep pace with the divider. Do not move the strip into
  toolbar items — items added or removed on a toggle jump while the column slides. A pane body
  must not reach into that zone: a background drawn into the top safe area, or a SwiftUI
  `ScrollView` (which stretches itself up under the title bar), covers the strip and takes its
  clicks — use `.paneSurface(ignoresSafeAreaEdges: [])`.
  The session toolbar is the run button and build title leading and the agent's controls in the
  middle; the pane section is the system's inspector toggle alone (`.toggleInspector`, the
  `sidebar.right` symbol), at the window's edge, which the strip keeps clear of
  (`SessionWorkspacePane.toggleInset`). It collapses the inspector column, and the workspace
  hears of it as of a collapse from the divider (`MainSplitViewController.paneCollapsedChanged`).
  Every tab is in the one strip and the one order (`WorkspaceContext.tabs`): web pages, open
  files, and the tools (`WorkspaceTool`) — Diff, the Simulator, Files (which browses the worktree
  as a tree), Live Monitor (the agent drawn live, `LivePanelView`), Terminal (a shell of its own in the
  worktree) and Chat (a headless chat of its own in the session's worktree, `PaneChatView`; see "Chat sessions"). The active tab decides what
  the pane shows; closing a tab selects its nearest neighbour. Diff's tab goes through the app, which loads the changes first, and over it
  the pane's next row is its review controls (`ReviewBar`: Changes/History, Commit and Push, the
  changed files' toggle); over a web page that row is its navigation and address (`.address`),
  whose suggestions hang under it. A simulator run opens the Simulator's tab, which closes when
  the preview ends. A blank page is a New Tab in the strip, and its start page offers the tools; the
  one the pane opens for itself when it has no tab is its empty state, not a tab
  (`WorkspaceContext.stripTabs`) — no tab and no New Tab button — until something is typed in it; the Files explorer is a Files tab that stays
  open, and each file picked there opens in a tab of its own. Files, Terminal and Chat are the tools
  with as many tabs as are opened, as pages are (`WorkspaceToolTab`); the others have one each. The strip shows its New Tab button once it has a tab, and New Tab takes
  the pane's own blank page rather than opening a second one. Closing the strip's last tab leaves
  the pane open on that empty state. When a screen's items do change,
  `MainToolbarController` edits the toolbar in place, taking out and putting in only the items
  that changed, rather than making a new toolbar, which re-laid out every item and jolted the
  whole bar.
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
