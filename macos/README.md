# Craft Native

Native macOS client ready for manual review. macOS 14+, Xcode 16.3+ and Swift 6.1+;
Apple silicon is the initial build target. Open `Craft.xcodeproj` in Xcode,
select **Craft → My Mac**, and press **Run** (Command-R). All app sources belong
directly to the Xcode project; no separate workspace or feature package is needed.

The Rust backend runs inside the app process: `crates/craft-backend` is linked as
a static library and the app dispatches its API calls straight into the backend's
router through the C ABI in `crates/craft-backend/src/ffi.rs` (Swift side:
`Services/Backend/EmbeddedBackend.swift`, header in `Vendor/CraftBackend`). No
child process, port or health handshake is involved, and every route, model and
contract stays the one the web client uses. The embedded backend still serves an
ephemeral loopback port, published in the data directory's `.server-port`, for
webhook forwarders, agent hooks and the web renderer. Only the Rust PTY helper
remains a separate process, so terminals survive an app restart. `--backend-path`
(with `--backend-port`) still runs a separate backend process, which the
integration tests use, and `--backend-url` attaches to an existing server.

Run is the only step. The scheme's Build pre-action runs `scripts/bootstrap.sh`,
which installs a Rust toolchain via rustup into `~/.cargo` if there is none,
downloads the prebuilt Ghostty VT runtime, builds the two Rust crates, and is a fast
no-op afterwards. Its log is `.build/bootstrap.log`.

The current local Release package is `macos/.build/review-20260913-appearance/`
(paths relative to the repository): `Craft.app`, ZIP, DMG and `release.json`.
The app includes its Rust backend and Rust PTY helper. It is ad-hoc signed for local
review, not notarized for public distribution. Release compilation and packaging
succeeded; no UI/unit tests or benchmarks were added or run in this closeout.

The app target owns the SwiftUI lifecycle, views, API client, SSE parser/client,
injected backend runtime, and `@Observable` AppViewModel. The current
screen has a Cocoa sidebar with project/session selection, Pinned mirrors, saved
Tabs, native terminal panes, and a native SwiftUI Dashboard.
Distribution is a directly downloaded
macOS app; there is no Apple App Store submission.

## Xcode organization

The folder layout follows `record-ios/Record`. Xcode uses synchronized folders, so
files added on disk appear in the corresponding group and target automatically.

```text
macos/
  Craft.xcodeproj
  App/                   Entry point, AppDelegate, root view and app state
  Scenes/                Dashboard, Projects, Jira, Activity, Settings, Workspace, Documents
  Coordinators/          Navigation and model lifetime, grouped by feature
  Components/            Reusable sidebar, terminal, tray and notification views
  Container/             Injected feature and platform factories
  Services/              Rust helper ownership, API/SSE, PTY and feature services
  Theme/                 Fonts and native appearance
  Utilities/             Shared deep-link helpers
  Resources/             Assets.xcassets and Configs/*.xcconfig/plist/entitlements
  Tests/                 CraftTests, helpers and the shared test plan
  UITests/               CraftUITests
  Tools/TerminalStress/  Optional CraftTerminalStress executable
```

`Craft`, `CraftTests`, `CraftUITests`, and `CraftTerminalStress` are Xcode
targets. Unit tests compile the same synchronized application source folders, with
the app entry point and delegate excluded; they have no application test host and
do not launch the daily app. The terminal diagnostic target uses the same source
membership and is built only through its separate scheme. Neither target copies
application sources or depends on a Craft Swift package.

`CraftApp: App` declares the single `Window` scene, default geometry, compact
toolbar, font environment, notification overlay and `CraftCommands` menus.
`AppDelegate` is connected through `NSApplicationDelegateAdaptor` for backend
startup, the status-item popover, deep links and asynchronous quit/update cleanup.
`AppCoordinatorView` is the window root: sidebar, detail column, destinations,
retained workspaces and coordinator-owned presentations. Each coordinator view owns
its screen's toolbar; a session workspace splits terminal and context pane with
`NativeSplitView`.

GhosttyTerminal (github.com/alexcding/ghostty-terminal-spm, Craft's fork of
libghostty-spm with the wrapper patches committed and a prebuilt XCFramework as its
binary target, pinned by exact tag) and Sparkle 2.9.6 remain
direct Xcode package dependencies. `GhosttySnapshotTests` stays a separate package
for validating the third-party terminal patches. Generated routes now live in
`Services/Backend/Routes.swift`.

The coordinator and DI split (see [`CLAUDE.md`](../CLAUDE.md)) follows the
`elevate-ios` responsibility split. Creation sheets now receive stable models from
an injected factory and an application coordinator. The completed view and runtime
boundaries are documented there, including typed actions and injected deep links.

Embedded frameworks must resolve from `Contents/Frameworks` in standalone launches.
The shared build configuration adds `@loader_path/../Frameworks` to inherited
runtime search paths for Debug and Release.
`macos/scripts/check-runtime-frameworks.py APP_PATH` checks the arm64 executable's
direct `@rpath` dependencies against files inside its bundle; backend bundling runs
this check before copying resources. This catches missing runtime search paths,
which build and code-signature verification alone do not detect.

## Cocoa sidebar (M2)

The sidebar is an AppKit `NSOutlineView`, hosted through `NSViewRepresentable`.
It supports native disclosure/keyboard selection, retained expansion and selection,
and context menus for pin/unpin, Finder reveal, and copying paths/links. Projects,
sessions, and tabs come from the existing backend snapshots and refresh via SSE.
Pinning requires the updated backend's `PATCH /api/tasks/:id/pin` endpoint.

Selecting a session shows its saved worktree and branch. **Open Terminal** opens or
reattaches its shell; switching sidebar rows swaps the detail view, while the session
keeps the emulator view — and with it the grid and scrollback — alive underneath. Pinned rows are additional entries for the same session. Browser
tabs now open embedded context pages with native controls. Sidebar implementation is authorized ahead of the remaining
M1 terminal acceptance checks, which are still open.

The `backend-fixture.cjs` script used to build an isolated sample hierarchy was
removed with Node support; the real Rust backend (`--backend-path`) is the only
fixture path now.

## Session workspace (M3, in progress)

**New Session** (Command-N) chooses a project, branch/base, agent, and optional page
URL. It creates or reuses a linked worktree and saves the session before opening its
native terminal. A newly created shell launches the chosen agent; reattaching a
running shell preserves its input. Restart requires confirmation and resumes a saved
agent conversation when its ID is known. Shell-only sessions launch no agent.

Context pages share persistent WebKit website storage and use a native page strip,
History, find bar, navigation, and AppKit split controls. Command-F finds in the page,
Command-brackets navigate, Shift-Command-brackets cycle pages, and Option-Command
plus/minus/zero zooms the page. Command-W closes a page while keeping its session;
with no page it hides the window. Page state is cached locally and synced to SQLite.
Up to six remote views remain live by default; General settings changes the limit
from one to twelve. Least-recently-used background pages suspend first and reload
when selected. Warning/critical macOS memory pressure suspends background browser
pages while retaining the active page. Suspended pages retain their tab identity and
shared website storage; unsent forms and in-page navigation state may be lost.
Editors, terminals and the Sprint board are outside this eviction policy.

The `test-browser-ui.sh` isolated browser UI regression script was removed with
Node support.

For real build/install/launch/Stop acceptance, first scaffold an isolated sample and
choose an available simulator from XcodeBuildMCP, then run
`CraftUITests/CraftUITests/testNativeRealBuildLaunchStopPreservesSessionTerminal`
directly against it (the `test-browser-ui.sh` wrapper that ran this is gone).

The opt-in test copies the sample into its private workspace, assigns a unique
personal probe bundle ID, and uses real Xcode routes and the native Run/Stop UI.
It verifies two launch/Stop cycles and retention of the ordinary session shell.
Cleanup stops only its probe app and verified fixture PTYs; diagnostics remain in
the printed fixture directory. The simulator and installed sample are retained.

Remove Session previews affected sessions and asks separately before discarding
uncommitted/untracked work. Orphan folders are retained. Xcode-configured projects
offer Run Destination and a separate Build pane; Stop interrupts its build PTY.
PR/Jira URLs resolve branches and existing ticket worktrees in the creation sheet.
Existing saved web/file tabs and history seed native contexts with one shared tab order. Terminal links and full session acceptance remain
under implementation; this does not close the M1 terminal acceptance gate.

## Native Dashboard (M4, in progress)

Overview renders native PR rows, CI/review states, labels, search, project filters,
and Mine/Review/Failing CI/Drafts filters. The review section retains open PRs already
commented on or approved, using `awaitingMyReview`; tray notifications keep the
strict requested-review classification. Snapshot reads and SSE drive updates; a
failed read retains the previous data and exposes Retry.

Opening a PR selects its existing session or creates a page-only context through
`POST /api/tabs`, which preserves other tabs and all existing editor state. The
context menu also opens the browser or copies the link. Agent usage uses the shared
native panel and refreshes once per minute while Overview is visible.
Complete workflow execution and action-parity acceptance remain M4 work.

Project rows now show native Open/Merged/All PR lists and a Settings tab. **New Project**
opens a native creation sheet. Settings include workspace selection, GitHub remote
detection, Jira key/JQL, and IDE configuration. Unsaved edits survive snapshot refreshes
and reconnects. Deleting a project requires confirmation and retains its sessions,
workspace folders, and terminals.

Every PR state reads a database snapshot immediately. Open contains every open PR;
Merged/All retain the existing latest-30 window in a separate cache. Stale reads
start a coalesced background fetch and update via SSE. Initial refreshes show progress;
failed refreshes keep cached cards and offer retry. Views bind state to the observable
model, which owns refresh, errors and cancellation.

**Workflows** is a native recipe editor with Claude/Codex selection, ordered steps,
goals, literal placeholder previews, and Save/Revert. Drafts survive navigation and
snapshot updates; failed saves keep the draft, and external recipe changes are
reported before replacement. Legacy `commands` arrays remain readable. Only the
`workflows` project field is sent on save, preserving automation and Xcode settings.
Saved recipes can run from native session workspaces. Run/Stop controls show the
current step and advisory summary; the Cocoa sidebar shows step progress. The runner
requires installed hooks, freezes the recipe for each run, allows one retry per step,
and halts on conversation/foreground/connection changes. Multi-line commands use
bracketed paste followed by a separate Enter. PR/Jira pages also expose the runner
when they map to one project. Preparation creates or reuses a worktree and transfers
the live page/editor context into a native session, retaining unsaved buffers. New
Jira workflow branches use the default branch; exact checkout verification rejects
unrelated branches sharing a folder. Stop drains a checkout already being created,
saves a recoverable shell session, and skips agent launch. Real-agent acceptance
checks remain in progress.

**Automation** is native too: forward GitHub events, set a Fix Version, then transition
linked Jira tickets when a PR merges. Its injected view model preserves drafts and
saves only automation fields. Preview Version evaluates the unsaved prefix/script
through the existing backend using a sample PR and reports existing version names;
it does not create a Jira version. Stale preview responses are discarded after edits,
navigation or reconnect. Actual merge actions still run through the existing backend.

**Tickets** is native SwiftUI. It reads the project's cached Jira feed, with local
text/facet filtering and saved filter preferences. An explicit search accepts keywords,
a ticket key, or JQL; SSE refreshes the feed without repeating the search. Status menus
offer known workflow statuses, and rejected transitions retain the original row.
Successful moves remain visible across stale snapshots while the existing explicit
sync action refreshes Jira. Ticket links open native contexts, with browser/copy actions
in the context menu. Services, search/filter state, and mutations live in an injected
view model; site discovery does not block the ticket feed.

**Sprint Board** remains web-based for now. Its focused WebKit page reuses the existing
board's filters, moves, assignment menus, and drag implementation. Ticket links open
native context pages; Option-click opens the browser. The board receives invalidations
from native SSE and releases its webview when you leave the section. No full SPA or
web terminal is loaded. Drag-gesture acceptance remains pending.

**Activity** (Command-3) is native, with category/error filters, search, copy, and
embedded PR opening. Clear Logs confirms the complete selected category, including
entries hidden by filters. Failed reads and clears keep the last available entries.

**Settings** (Command-comma or sidebar) has native General and Connections sections.
General shares the tray's offline-safe theme/notification preferences, adds the full
macOS sound list and explicit preview, and persists the default agent for new sessions.
Connections edits polling intervals, Jira site, token, and ticket limit. Saves send
only changed fields and preserve drafts on failure/reconnect. Interval edits reschedule
only running backend loops; saving to a fixture does not start polling.
The **Integrations** section probes installed tools and sign-in state on demand, offers
installation guides and login-command copying, and installs/removes agent hooks.
Unknown authentication remains distinct from signed out. Hook edits reject malformed
configuration and preserve other commands, permissions, and dotfile symlinks.
**Diagnostics** reads database counts, GitHub/Jira/Sprint snapshots, sync failures,
and CLI timing counters. It refreshes while visible without running CLI commands.
General also configures the external Git client. Session toolbars open the current
worktree in that client or the project's configured IDE, resolving Xcode targets
through the backend. Custom commands group arguments with quotes and substitute
`{path}` literally; they do not perform shell expansion or pipelines.

**Launch at login** reads macOS ServiceManagement state directly, including pending
approval, and links to Login Items settings when approval is needed. Registration
is available only in packaged release builds with a bundled backend; development
builds may remove an existing native registration. No login item is registered on
startup or by opening Settings. Login launches open the app normally with its window
and Dock icon. A legacy Tauri login item is separate and is not automatically changed
by the native app. Real registration and logout/login acceptance remain part of
packaged-release verification.

**Code fonts** offers installed monospace families and independent terminal and
code/diff sizes (9–24 points). Preferences share the existing backend keys, retain
unavailable saved families, and apply immediately to mounted views. Terminal changes
preserve the native surface and shell; editor changes preserve unsaved text and undo
state. Saves coalesce rapid size changes and retain pending values while offline.
The native browser policy uses a page count and OS memory-pressure events, with a
manual **Suspend Background Pages** action. It uses no private per-webview PID/RSS
API, does not claim a byte-level cap, and leaves the web app’s `webviewBudgetMb`
setting untouched.

**Resources** displays native process CPU and resident memory for the app, connected
backend, detached PTY helper, and their descendants. It discovers backend/daemon PIDs
through read-only handshakes; opening this page never starts a missing daemon. CPU
uses deltas between samples (100% is one core). Sampling runs off the UI actor on a
three-second cadence while the page is visible and the AppKit app is active.
Leaving the page, hiding/deactivating the app, and shutdown stop the loop.
Errors retain the last successful sample; unavailable process reads are reported.
macOS-managed WebKit/GPU processes outside those trees are excluded, and summed
resident memory may double-count shared pages. The displayed totals cover the listed
processes, not the app’s complete memory footprint or the terminal benchmark.

## Native tray and appearance (M2)

Click the menu-bar icon or **Reviews & Usage** in the window toolbar to open the
native popover. It shows pending review requests with CI status, saved Mine/Review/
Jira/Web tabs, and Claude/Codex usage. Review requests open in the browser and are
then marked opened; saved tabs select their owning native session or tab detail.
Embedded browser routing remains M3 work.

PRs refresh through snapshot APIs and SSE. Usage loads separately on opening or
refreshing the panel, retaining previous data on error. Appearance (System/Light/Dark)
and the selected usage agent persist to the existing backend settings database.
The menu-bar icon is bronze for pending reviews, blue for open work, and neutral
when idle. Escape or clicking outside closes the panel. Quit is owned by the app
menu and Command-Q, not duplicated inside the tray panel.

For sample PRs/usage, add `CRAFT_TRAY_FIXTURE=1` to the isolated fixture command.
This replaces usage reads with synthetic data; no credentials or usage CLIs are
accessed. Automated tests can hold usage with `CRAFT_HOLD_USAGE=1` until the
fixture data directory contains `release-usage`, or create `fail-usage` to test
retention on failure. Usage includes reserve/over-pace indicators using the existing
five-hour session and seven-day weekly windows.

Native File/Edit/View/Go/Window menus are owned by AppKit. Copy/paste/undo follow
the focused responder. Command-1 opens Overview, Command-2 focuses the terminal,
Control-Command-S focuses the sidebar, and Control-Command-T reveals/focuses the
current terminal. The close button puts the window away (no animation; Dock click restores it); Command-Q and Dock/app-menu Quit tear down the app.
Command-plus/minus/zero changes or resets the visible code/diff font, or the terminal
font when no code document is visible, without recreating its emulator. In General
settings these shortcuts change the code/diff size. Page zoom remains separate.

## Notifications (M2)

The tray's **Notifications** section offers **Enable Notifications**, activity alerts,
and the review sound choice. Permission is requested only when you click Enable;
macOS notification denial and delivery errors are shown in the panel. System sound
authorization is respected. The default review chime is Glass; None disables it,
and an existing custom sound from backend settings is retained.

The first successful review snapshot seeds silently. New request timestamps trigger
one notification per PR and one sound per batch. Reviews already opened or merely
in the broader review group do not alert. Backend reconnects retain the seed.

Activity arriving over SSE appears as a native toast while the main window is focused,
otherwise as a macOS notification. Recent activity stays in the tray (latest 20 during
this app session), including when activity alerts are switched off. Clicking a PR
notification opens its validated URL in the browser and marks a review opened only
after browser acceptance. Other activity opens the native tray. Embedded navigation
and the complete Activity page are still pending.

Automated notification tests use an injected recorder: no real permission prompts,
notifications, or sounds. Real Notification Center permission/banner/click acceptance
remains an interactive check on the bundled app. Permission and the foreground
activity toast have been verified; automated OS banner inspection timed out.
For isolated manual checks, add `CRAFT_NOTIFICATION_FIXTURE=1`, then write
`{"type":"activity"}` or `{"type":"review"}` to `notification-command.json` in the
fixture data directory. The fixture consumes that file and emits synthetic events.

## Build and run

From the repository root, `macos/scripts/bootstrap.sh` does everything the scheme
needs (the Xcode scheme runs it itself); the individual steps it performs are:

```bash
npm ci --ignore-scripts
npm run gen:swift-routes            # or check:swift-routes; the output is committed
macos/scripts/bootstrap.sh          # rustup if needed, prebuilt Ghostty VT runtime, both crates
xcodebuildmcp macos build --project-path macos/Craft.xcodeproj --scheme Craft --derived-data-path macos/.build/xcode --arch arm64
```

Open `macos/Craft.xcodeproj` and Run **Craft**. The shared scheme already selects
the development child using paths relative to the project. The app starts the
server itself; do not start a second server for this Run configuration.

To override that default, choose a backend mode through the Xcode scheme's launch
arguments or the launch command's `--launch-args` option:

- Existing server: `--backend-url http://127.0.0.1:3000`. The server must include the
  new `/api/backend/health` endpoint. The native app never stops an external server.
- Development child: `--backend-root /absolute/path/to/repo`, or
  `--backend-path /absolute/path/to/craft-backend`.
  Add `--backend-port 43187 --data-dir /absolute/path/to/isolated-data` to isolate it
  from your daily app.
- Bundled child: disable the shared Run scheme's development arguments. The app expects the bundle resources below.
  It defaults to port 3000 and `~/Library/Application Support/Craft`, respecting
  `CRAFT_DATA_DIR` or `--data-dir`.

A port conflict fails visibly; the app never kills by port or adopts a foreign process.
Command-Q and Dock/app-menu Quit stop the owned backend and every session PTY, then
exit. On launch, every saved session gets a new terminal and its saved
Claude or Codex conversation is resumed. Quit waits for PTY teardown; a failure keeps
the app open with an error so teardown can be retried.

## Working diff

Select a session and choose **Show Changes**. The diff displays tracked and untracked
changes and supports file navigation, commit/push, and guarded single-block discard.
`DiffViewModel` receives snapshots through an injected `DiffService` and pushes them to
the bundled diff page (`Resources/DiffPage/`) in a `WKWebView`. The page renders the
rows: syntax highlighting, two-tone add/remove gutters, sticky collapsible file headers,
status badges, a hover frame with a hover-only **Discard**, and stubs for binary and
oversized files. It has no network access and is served by `DiffPageAssets` on the
`craft-diff://` scheme; opening a file and discarding a block are messages back to
Swift, which owns loading, the confirmation sheet and every mutation. The unit-test
bundle carries no app resources, so `DiffTests` points `DiffPageAssets.directoryOverride`
at the source tree and renders the real page in a real web view.

The shared editor save contract now uses `/api/file` revisions. Reads return an
opaque revision; saves must submit it and retain the returned revision for the next
save. A stale revision fails without replacing the observed newer file. Edits stage
beside the destination before rename, preserving macOS file metadata and symlinks.
Hard-linked files are read-only. The AppKit editor retains edits made while a save
is in flight.

## Native terminal

Current implementation: native Ghostty rendering backed by detached PTY sessions,
snapshot v3 (text/history, parser continuation, glyphs and Kitty graphics), and
daemon-owned state, identity, geometry, graphics and appearance replies. The
appearance handshake revision is `-taskhub-appearance-v3`. Clipboard and other UI
effects remain native and live; detached UI requests are not queued or replayed.
See [the protocol policy](../crates/craft-ptyd/SNAPSHOTS.md#native-live-ui-policy).
The user's manual app review is pending. Historical acceptance and benchmark notes
below are retained for reference; no more UI/unit tests or benchmarks are scheduled.

Build the pinned runtimes using the commands above, then build the standalone
helper with `cargo build --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots`.
For development, add `--ptyd-path /absolute/path/to/repo/crates/craft-ptyd/target/debug/craft-ptyd`
to the app's launch arguments; a bundled app uses `Contents/Helpers/craft-ptyd`.
Opening a saved session starts its native terminal automatically. The terminal surface
has no diagnostic status bar; connection recovery remains internal.

GhosttyTerminal uses the source-built local package generated from
`Lakr233/libghostty-spm` **1.6.20260909**, revision
`7e45d27160f9b34aca9ca5c9820e9207482f9f04`, with Craft's maintained snapshot and
ordered-grid patches. The source builder requires Apple's Metal compiler component.
Socket I/O and output parsing run off the UI actor. Replay waits for actual parser
consumption before enabling input; output uses byte-counted flow-control watermarks.
Native connections negotiate `dataEncoding: "base64"` in the protocol-2 hello.
PTY output, attachment history, and keyboard input preserve exact bytes through
JSON `bytes` fields. Ghostty owns decoding, including incomplete UTF-8 across the
replay/live boundary. Tauri clients keep their existing `chunk`/`buf` text protocol;
both representations share one output sequence. An old helper without byte support
is detected before the native pane creates or attaches a shell.

The spike intentionally uses `craft-native-ptyd.sock` in the same private socket
directory convention as Tauri, and `ptyd-native-spike` under the selected data directory.
It does not attach to daily Tauri sessions. `--pty-socket` or `CRAFT_PTYD_SOCK` can
override this; use a separate test socket because explicit Quit tears down the
connected daemon's sessions.

Attachment negotiates the exact snapshot
revision, downloads a bounded binary capture, imports it into a fresh native
surface, and drains newer output/resize events in daemon order before enabling
input. History beyond the old 256 KiB tail is retained. Incompatible helpers are
rejected before shell creation; invalid captures and sequence gaps stop attachment
without terminating the shell. The capture supplies its logical grid even if a
physical view resize is still pending. Restored titles and working directories use
native callbacks; only local working-directory URIs become file-link bases, and
an empty directory report clears the previous base. The versioned
`daemon-state-v1` response owner covers status/cursor, mode (except Kitty clipboard mode),
DECRQSS and Kitty keyboard queries keep working without a viewer. Newly created
shells now select `daemon-identity-v1`, adding DA/version/terminfo replies and using
`TERM=xterm-ghostty` with the actual renderer version. The daemon keeps a private
copy of bundled terminfo until the shell exits, independent of app relocation or
rebuild. Existing state-owned shells retain their original profile. Native surfaces
suppress the matching set after import/reconnect; keyboard, paste and UI effects
keep their native paths. Unsupported helpers/owners are rejected without replacement.
New sessions also retain the pinned package's shell integration scripts. Zsh's
bootstrap preserves user startup files and prompt hooks while publishing working
directory and command boundaries, so a cd updates native file-link destinations.
Non-Apple Bash uses Ghostty's ENV startup mechanism; Apple Bash and other unsupported
shells retain normal startup behavior. These scripts are never written into user
dotfiles. Craft snapshot v3 retains glyph registrations using the same maintained
patch in the daemon and renderer. The format is negotiated explicitly; older
daemons remain running and are rejected rather than silently upgraded. Kitty image
state and daemon appearance replies are implemented; see
`crates/craft-ptyd/SNAPSHOTS.md`.

New app sessions also select `daemon-geometry-v1`. They wait for measured cell
pixels before creation; kernel winsize, parser state, ordered resizes and snapshot
metadata share those measurements. Native surfaces suppress the matching replies,
including mode 2048 resize notifications, so two attached surfaces do not duplicate
responses. Older identity/state sessions retain their existing response paths.
Resize requests are acknowledged and queued in callback order; rejected resizes
stop the pipeline visibly. Transport loss uses the existing reconnect/input-safety
checks. Unchanged grid/cell measurements skip a request, while changed cell pixels
remain significant. The native callback runs at the engine resize boundary and
reports actual font metrics, including backing-scale rounding. Snapshot/event
geometry and ownership are validated before use.

Rebuilding the helper does not upgrade an already-running daemon; use an isolated
socket to test the new helper without ending an existing shell. Broader
lifecycle coverage, links, workflow hooks, IME/mouse/selection checks, and the
ten-minute multi-session performance benchmark remain part of M1's acceptance gate.

The standalone `CraftTerminalStress` Xcode executable exercises ten real
native sessions with a visible interactive terminal, one hidden flood and eight
hidden tickers. It writes machine/build metadata, input-to-parsed-output latency,
queue peaks and native process CPU/RSS. Run it with an already-prepared Ghostty
package and helper, only when explicitly running the benchmark:

```bash
cargo build --manifest-path crates/craft-ptyd/Cargo.toml --release --features terminal-snapshots --locked
xcodebuildmcp macos build --project-path macos/Craft.xcodeproj \
  --scheme CraftTerminalStress --configuration Release --arch arm64 \
  --derived-data-path macos/.build/terminal-stress
macos/.build/terminal-stress/Build/Products/Release/CraftTerminalStress \
  --seconds 600 --root /absolute/path/to/cli-task-hub-swiftui \
  --helper /absolute/path/to/cli-task-hub-swiftui/crates/craft-ptyd/target/release/craft-ptyd \
  --report /tmp/craft-terminal-stress.json
```

Check the final report and process completion. Do not overlap it with builds, UI tests or
another benchmark. The first ten-minute result
recorded 20.51 ms input-to-parsed-output p95 and bounded queues. GPU/display latency,
memory stabilization and an equivalent Tauri comparison remain open.

An established terminal automatically reconnects after a transient transport loss
when all input has been acknowledged. It replaces the native surface and restores
the same terminal ID/PID from a fresh snapshot, using up to five attempts with
backoff. Reconnect never launches a replacement daemon or shell. Pending or failed
keyboard input, app-issued commands and interrupts are never replayed. Removing the
pane cancels recovery and rejects stale callbacks.

## Native editor documents (M5, in progress)

Choose **Open File** (Command-O) from a session/page context. File tabs share the
native page strip and History; CodeEditSourceEditor (an AppKit text view with tree-sitter
highlighting) renders the editor, while Swift owns file I/O, revision conflicts, and document
lifecycle through injected services and factories. Settings → Text Editor picks the code font,
one colour theme per appearance, and whether the code preview shows beside the text.
Command-S saves, Command-F finds, and Command-W closes with Save/Discard/Cancel when
needed. Session removal and app termination check unsaved documents before stopping shells.
Hidden clean editors unload; unsaved editors retain their buffer and undo history.
Unsaved text is not persisted for crash recovery. Files must be UTF-8 text, at most
5 MB; hard-linked/unwritable files are read-only. Failed saves preserve edits.

The editor uses the revision-checked Rust file API. The Sprint Board and diff are
native SwiftUI surfaces; browser tabs remain WebKit because they display GitHub and
Jira themselves, not bundled Craft JavaScript.

## Local bundle smoke test

```bash
bash macos/scripts/bundle-backend.sh /absolute/path/to/Craft.app
xcodebuildmcp macos launch --json '{"appPath":"/absolute/path/to/Craft.app","launchArgs":["--backend-port","43187","--data-dir","/absolute/path/to/isolated-data"]}'
```

The bundle script builds and copies the release Rust backend and PTY daemon, copies
only toolbar image resources, signs the helpers, then signs the app. It does not run
npm or copy Node, `src/server`, `src/shared`, or renderer code.
Use an absolute app path. This is a development bundle, not a notarized release.
Inspect `Contents/Helpers` to verify the two Rust helpers and confirm that no
`Contents/Resources/backend` tree exists.

Distribution is a direct Mac app without App Sandbox: Craft orchestrates local CLIs,
worktrees, and detached PTYs. Developer ID signing, hardened-runtime entitlements and notarization are wired
through `scripts/package-direct.py`; execution with real credentials and signed
update installation remain external release work. The native
bundle identifier is `com.alexcding.craft`, owned by Alex Ding. UI tests use
`com.alexcding.craft.uitests`. The earlier development identifier is retired; its
UserDefaults/WebKit identity is separate. The shared SQLite data directory remains
`~/Library/Application Support/Craft`.

### Native updates

Sparkle **2.9.6** is pinned in the Xcode project and embedded by Xcode, including
its installer and XPC services. The bundle script includes its upstream license
at `Contents/Resources/Licenses/Sparkle-LICENSE`. The native application menu has
**Check for Updates…**, enabled only after a packaged Release app successfully
starts its updater. Debug builds, unbundled builds, and builds without a valid
HTTPS feed and 32-byte Ed25519 public key leave the updater inactive.

Release configuration supplies `CRAFT_UPDATE_FEED_URL` and
`CRAFT_UPDATE_PUBLIC_KEY`; `Resources/Configs/App-Info.plist` maps these into `SUFeedURL` and
`SUPublicEDKey` alongside Xcode's generated app metadata. In an xcconfig, escape the URL's double slash with an empty build
setting (`https:/$()/updates.example.org/appcast.xml`) to avoid a comment. Supply
the real release endpoint and public key; keep private update keys out of the app
and repository. No feed or signing key has been provisioned by this migration.
Sparkle retains its standard permission prompt and automatic-check preference.

An update restart waits at AppKit's termination boundary for the existing
Save/Discard/Cancel editor flow and outstanding workspace operations. Cancel
keeps the app open and permits the installer to retry. On approval, Craft stops
its workflow automation, terminal sessions, PTY daemon, and owned Rust backend.
The relaunched app recreates saved sessions and resumes their CLI conversations.
Real signed feed download/install/relaunch and upgrade/rollback acceptance remain
release gates.

### Data recovery

The Rust helper provides `backup`, `verify`, and `restore` commands and reads the
previous format-1 snapshots. Packaged startup holds the native data ownership lock
and verifies a pre-migration checkpoint before opening existing databases. See
[Data recovery](../docs/DATA-RECOVERY.md) for the commands and state inventory.

## Verify

```bash
npm run check:swift-routes
node --test --test-force-exit test/contracts.test.js test/swift-routes.test.js test/api.test.js
xcodebuildmcp macos test --project-path macos/Craft.xcodeproj --scheme Craft --derived-data-path macos/.build/unit-tests --extra-args '-only-testing:CraftTests'
cargo test --manifest-path crates/craft-backend/Cargo.toml
cargo test --offline --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots
cargo check --offline --manifest-path src-tauri/Cargo.toml
xcodebuildmcp macos test --project-path macos/Craft.xcodeproj --scheme Craft --derived-data-path macos/.build/ui-tests --extra-args '-only-testing:CraftUITests'
```

Some legacy Swift integration fixtures still require Node; production builds do not.
They use temporary data and never touch production databases. Tests cover route escaping,
bounded SSE framing, Unicode, API identity, snapshots, real SSE, and backend ownership.
Terminal tests use isolated sockets and temporary shell scripts; they never connect
to daily Craft sessions. Native surface tests create an unshown Metal-backed
AppKit window and verify Unicode, alternate-screen restoration, hidden parsing,
Enter encoding, and bracketed paste without touching the system clipboard.
The native pipeline test also races output against an attachment snapshot, rejects
duplicate sequences, completes a Unicode character split across that boundary, and
checks final parsed output before exit while hidden. A real PTY round-trips all 256
byte values with raw mode enabled, reattaches to identical bytes, and verifies that
incomplete UTF-8 is delivered immediately. Rust integration tests attach native byte
and legacy text clients to the same PTY, checking invalid input, split codepoints,
both attachment formats, shared sequences, and continued legacy input support.
Regressions cover invalid geometry, replay, and protocol byte-transport contracts,
malformed daemon-startup errors, and an unbounded resize-event flood. The
`pty-protocol-fixture.cjs` Unix-socket peer these once ran against error cases
without launching any shell was removed with Node support, along with the
timeout/disconnect, mismatched-helper, and snapshot-download regressions it backed.

The daemon implementation now lives in `crates/craft-ptyd/src/lib.rs`. Tauri re-exports
the same crate; do not create a second implementation. M1 fixes its incremental
UTF-8 decoder so invalid input cannot stall later output, and allows the standalone
helper to detach when Foundation launches it as a process-group leader. Protocol 2
remains compatible. Screen restoration and the remaining fidelity/performance checks
must pass before we call the native terminal ready.


Diff Open File and current-file line buttons now open native editor tabs, as do
Ghostty-activated local-file links. Web links open in the owning workspace, and the
standalone terminal supports the same split context pane as session terminals.
Line/column locations survive document loading. Diff paths stay within the
canonical worktree; terminal relative links use the current working directory.
Command-click recognizes printed paths (including wrapped paths and `:line:column`)
through the pinned core's default matcher. While a TUI captures the mouse, use
Shift-Command-click to release capture. Option-click routes web links to the real
browser and also respects Ghostty's capture override. Ordinary clicks retain TUI
mouse reporting. Paths remain scoped to their originating terminal's workspace.


Changes → **Commit and Push…** opens native commit controls. Commit stages all
tracked changes, optionally includes untracked files, and uses the existing Git
signing/hooks. A failed push preserves the successful local commit and offers
Push without repeating Commit. Failed commit drafts survive; failed refreshes
disable actions until disk state is loaded again. Quit waits for running Git
operations. The native SwiftUI diff renders the patch.


Working diff blocks also offer **Discard**. A native sheet previews the exact patch
before **Discard Block**; Cancel makes no changes. The backend verifies the reviewed
diff revision again when applying, so stale confirmations ask for refresh and review.
Failed operations retain their error and proposal. Block selection is typed and
scoped to the originating worktree; the UI never submits arbitrary patches.

## Direct-distribution packaging

`macos/scripts/package-direct.py` stages the completed bundle into a new output
directory and produces `Craft.app`, `Craft.zip`, `Craft.dmg` and a checksum
manifest. It preserves the input app and never installs or publishes anything.
Use a new output directory on every invocation. UI/unit testing and benchmarking
remain deferred by user direction; packaging does not run them.

For a local review build, first build the Release scheme with XcodeBuildMCP and
run `bundle-backend.sh`, then:

```sh
python3 macos/scripts/package-direct.py --local \
  --app /absolute/path/to/Craft.app --output /absolute/path/to/new-review-directory
```

For a release, supply your existing Developer ID Application identity and an
existing notarytool Keychain profile:

```sh
python3 macos/scripts/package-direct.py \
  --app /absolute/path/to/Craft.app --output /absolute/path/to/new-release-directory \
  --identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --notary-profile CRAFT_NOTARY
```

The script signs embedded code from the inside out with hardened runtime,
notarizes the app archive, staples the app, then creates,
signs, notarizes and staples the disk image. A rejected notarization cannot be
reported as a release. Release mode requires a Release build with the personal
bundle ID. No signing identities, Apple credentials or update private keys are
stored by the script. The native bundle includes Ghostty, wrapper and theme
licenses alongside the Sparkle notice, and the licenses of the file editor's packages
(CodeEditSourceEditor and what it links). Two of those, CodeEditLanguages and
CodeEditSymbols, publish no license file at their pinned versions; confirm their terms
with upstream before a public release.

Developer ID and notarization credentials have not been provisioned. The signed
release path is implemented but has not been executed. Configure the real HTTPS
Sparkle feed and public key when building a release; sign the final archive with
your private Ed25519 key before publishing an appcast. No feed is published here.

The current Rust review package is `macos/.build/review-20260914-rust-final/`, containing
an app, ZIP, DMG and checksum manifest. Earlier review directories predate this
cutover. This is an ad-hoc local package; manual review is still pending.
