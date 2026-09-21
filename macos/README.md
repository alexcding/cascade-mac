# Craft for macOS

This guide covers the native app's development workflow and individual surfaces.
Start with the [project README](../README.md) for setup and
[AGENTS.md](../AGENTS.md) for architecture, ownership rules, and coding conventions.
All commands below run from the repository root unless stated otherwise.

## Build and run

The app targets macOS 14+ on Apple Silicon. Building the current source requires
Xcode 26+ for the macOS 26 SDK, on a Mac that supports that Xcode version. The Rust
backend requires Rust 1.88+.

```bash
open macos/Craft.xcodeproj
```

Select **Craft → My Mac** and press **⌘R**. The shared scheme runs
[`bootstrap.sh`](scripts/bootstrap.sh), which installs Rust through rustup if Cargo
is missing, downloads the pinned Ghostty VT runtime, and builds the Rust backend
and PTY helper. It also bundles the PTY helper during the app build. The first run
needs network access; subsequent builds are incremental. Bootstrap logs are in
`macos/.build/bootstrap.log`.

For a command-line build:

```bash
xcodebuild build -project macos/Craft.xcodeproj -scheme Craft \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/.build/xcode
```

To prepare just the Rust libraries and native runtime, run
`bash macos/scripts/bootstrap.sh`. No npm install or route-generation step is
required. API route constants are maintained in
[`Routes.swift`](Services/Backend/Routes.swift); the Rust `route_contract` test
checks them against the router.

## Xcode organization

Xcode uses synchronized folders, so source files added on disk appear in the
corresponding group and target automatically.

```text
macos/
  Craft.xcodeproj
  App/                   App entry, lifetime, commands, and root state
  Scenes/                Dashboard, projects, Jira, documents, settings, welcome, workspaces
  Coordinators/          Navigation, presentation, and model lifetime
  Components/            Shared sidebar, terminal, tray, and other UI
  Container/             Injected feature and platform factories
  Services/              Backend, terminal, workspace, and integration services
  Theme/                 Appearance, fonts, and design tokens
  Utilities/             Deep-link routing
  Resources/             Assets, build settings, status-line script, and diff page
  Tests/                 CraftTests and the shared test plan
  UITests/               CraftUITests
  GhosttySnapshotTests/   Separate package for terminal bridge tests
  Tools/TerminalStress/  Optional terminal benchmark
```

`Craft`, `CraftTests`, `CraftUITests`, and `CraftTerminalStress` are Xcode targets.
Unit tests compile the application source folders with the app entry point and
delegate excluded; they have no application test host. The stress target uses a
separate scheme. `GhosttySnapshotTests` is a separate Swift package outside the
shared test plan.

The app's direct package dependencies are GhosttyTerminal, CodeEditSourceEditor,
and Sparkle. Their versions are pinned in the Xcode project and resolved package
file. The Ghostty package supplies the prebuilt rendering framework; bootstrap
fetches the matching headless runtime. See the
[Ghostty patch guide](patches/ghostty/README.md) when changing either side.

The [native architecture guide](../AGENTS.md#native-app-architecture) explains
coordinators, factories, view-model actions, and how to add a screen.

## Backend and local data

By default, `craft-backend` is a Rust static library linked into the app. Requests
pass through `APIClient` and `EmbeddedBackend` to the axum router over a C ABI;
normal app requests do not use a separate server process. The embedded backend
also opens an ephemeral loopback port for agent hooks and webhook forwarders,
recorded in the data directory's `.server-port` file.

GitHub and Jira lists read SQLite snapshots while background polling refreshes
them. Embedded mode delivers events directly to the app; separate-backend modes
use server-sent events. Preserve this snapshot model when adding data to a screen.

For debugging, set launch arguments in the Xcode scheme:

| Argument | Behavior |
| --- | --- |
| `--backend-root /absolute/path/to/repo` | Marks a checkout launch as development; the backend remains embedded. |
| `--backend-path /absolute/path/to/craft-backend` | Starts and owns a separate Rust backend process. Use `--backend-port` to choose its port. |
| `--backend-url http://127.0.0.1:43187` | Connects to an existing backend; Craft never stops that external process. |
| `--data-dir /absolute/path/to/data` | Selects the app's data directory; `CRAFT_DATA_DIR` is the environment equivalent. |
| `--ptyd-path /absolute/path/to/craft-ptyd` | Uses a particular terminal helper build. |
| `--pty-socket /absolute/path/to/socket` | Selects a terminal daemon socket; `CRAFT_PTYD_SOCK` is the environment equivalent. |

A different data directory alone does **not** isolate terminal sessions. Use a
separate private socket for manual tests: explicit Quit stops the connected
terminal daemon and its shells. Socket paths must be absolute and shorter than
104 UTF-8 bytes. The current default socket filename is `craft-native-ptyd.sock`;
terminal metadata is stored under `ptyd-native-spike` in the selected data directory.
These internal names are retained for compatibility.

The default data directory is `~/Library/Application Support/Craft`. `craft.db`
holds durable projects, sessions, tabs, and settings; `data.db` holds refreshable
snapshots and `logs.db` holds activity. Worktree files and agent conversations live
in their own locations. See [data recovery](../docs/DATA-RECOVERY.md) for backup
and restore semantics. The recovery CLI can be built from `crates/craft-backend`;
the standard app bundle does not include a separate `craft-backend` executable.

## Sidebar and session workspace

The sidebar is an AppKit `NSOutlineView` with projects, sessions, saved tabs, and
pinned entries. It preserves selection and ordering and provides context actions
for opening, pinning, removing, and revealing items.

**New Session** (**⌘N**) belongs to the selected project. Enter a branch name, PR
URL, or Jira ticket URL, choose a base branch, and pick Claude, Codex, or Shell
only. Creation resolves the context, creates or reuses a worktree, saves the
session, and opens its terminal. A session is a saved task record; a worktree
without a session does not appear automatically.

Each workspace retains its terminal and context panes as you switch tasks. Browser
pages use WebKit with shared website storage, tabs, bookmarks, history, find, and
navigation controls. Files open in native editor tabs. The session toolbar can
open its worktree in the configured IDE or Git client. Xcode projects also support
scheme/destination selection and build, launch, and Stop controls.

Removing a session previews the affected work and requires separate confirmation
before discarding uncommitted or untracked changes. Restart stops that session's
shell after confirmation and resumes a saved agent conversation when an ID is
available. Removing a project keeps its workspace folders and sessions.

Closing the main window keeps Craft and its sessions running. **⌘Q** and update
restart check unsaved documents, stop workflows and terminals, stop the owned
backend, and then exit. Cancelling a document close keeps the app open. An
unexpected app exit can leave the detached shells alive for reattachment.

## Dashboard, projects, and Jira

The dashboard groups your pull requests separately from the ones in your review
queue, with search, project/status filters, and CI information. Review grouping
uses `awaitingMyReview`, including PRs you have already reviewed; menu-bar alerts
use the narrower active-review-request classification. Failed refreshes preserve
the last successful snapshot and offer retry.

A project's available sections depend on its integrations: GitHub enables Pull
Requests and Automation; a Jira project key or JQL enables Tickets and Sprint
Board. Workflows and Settings remain available for local projects.

Tickets and Sprint Board are native SwiftUI surfaces. They read cached Jira data,
provide filters, and support ticket actions. The board has status drop targets
for moving tickets. Optional Jira REST features, including board-column discovery
and Fix Version assignment, require an API token in **Settings → Integrations**.

Workflows save ordered prompts per project, with Claude/Codex selection and
placeholders such as `{branch}`, `{worktree}`, and `{url}`. The runner requires
agent hooks installed through **Settings → Integrations**. It captures the recipe
for each run, follows agent turn boundaries, allows one retry per step, and stops
when its terminal or conversation changes. Saving a workflow updates only the
workflow fields of the project.

Automation can forward GitHub events and apply Fix Versions and status transitions
to linked Jira tickets after a PR merges. Version preview evaluates the draft
without creating a Jira version. Polling still handles merges when webhook
forwarding is unavailable.

## Diff and editor

Working changes are rendered by a bundled HTML/JavaScript page in a `WKWebView`.
`DiffViewModel` loads the snapshot through an injected service and pushes it into
the page. `DiffPageAssets` serves an allowlist of bundled files on `craft-diff://`;
the page's content policy forbids network connections. File-open and discard
intents return to Swift, which owns loading, confirmations, and mutations.

**Commit and Push** commits tracked changes, optionally includes untracked files,
and uses Git's configured signing and hooks. Save editor buffers first to include
them. A failed push preserves a successful local commit and can be retried without
committing again. **Discard** previews the selected change block; the backend
rechecks the diff revision before applying it. A stale preview requires a refresh.

The file editor uses CodeEditSourceEditor with tree-sitter highlighting. **⌘O**
opens a file, **⌘S** saves, and **⌘W** closes with Save/Discard/Cancel when needed.
Files must be UTF-8 text and at most 5 MiB; hard-linked or unwritable files are
read-only. Saves use the Rust file API's revision checks so a stale buffer does
not silently replace newer disk contents. Failed saves retain edits, including
edits made while a save is in progress. Unsaved buffers are not persisted for
crash recovery.

Diff file links and terminal file links open native editor tabs with line/column
locations. Diff paths remain inside the worktree; terminal relative paths resolve
from the terminal's working directory. Web links can open in the workspace or,
with Option-click, the external browser.

## Terminal stack

GhosttyTerminal renders the native terminal. `craft-ptyd` owns detached PTYs and
communicates with the app over a Unix socket. `craft-vt` maintains headless Ghostty
state for snapshots. The daemon and renderer must use matching patched Ghostty
revisions; update both the Xcode package pin and bootstrap release together.

Attachment negotiates the snapshot format, imports a bounded capture into a fresh
surface, and drains newer events before enabling input. Socket I/O and parsing
run off the main actor. Native transport preserves bytes with base64 framing,
including UTF-8 sequences split across messages. Snapshot v3 includes terminal
history, parser state, glyphs, and Kitty graphics.

The daemon owns negotiated terminal replies so detached shells can keep working.
Shell integration resources and terminfo are retained independently of the app's
location; user dotfiles are not rewritten. Invalid snapshots and incompatible
helpers are rejected without silently replacing a running shell.

A transient disconnect can reconnect to the same shell when all input has been
acknowledged. Pending or failed input is never replayed. Rebuilding the helper
does not upgrade an already-running daemon; use an isolated socket to test a new
helper. Full protocol details are in
[terminal snapshots](../crates/craft-ptyd/SNAPSHOTS.md) and the
[headless runtime guide](../crates/craft-vt/README.md).

## Settings, menu bar, and notifications

Settings uses the visible sections **General**, **Browser**, **Terminal**,
**Text Editor**, **Integrations**, **System**, and **Activity**.

- **General** controls appearance, the default agent, notifications, the external
  Git client, and launch-at-login preferences.
- **Browser** manages browsing data and the optional ad blocker.
- **Terminal** and **Text Editor** configure their own fonts and themes. Terminal
  settings come from Craft, rather than an installed Ghostty app's configuration.
- **Integrations** probes CLI installation and sign-in state, installs/removes
  agent hooks, and configures polling and Jira. Hook changes preserve unrelated
  configuration. The first-launch guide can be reopened here.
- **System** shows process resource usage and database/snapshot diagnostics.
- **Activity** provides event search, category/error filtering, copy, and log
  clearing with confirmation.

The menu-bar popover shows pending review requests and available Claude/Codex usage.
Its icon is bronze for pending reviews, blue for open work, and neutral when idle.
The first successful review snapshot seeds notifications silently; later review
requests can trigger alerts and the configured sound. Notification permission is
requested through the user's explicit action. The sidebar bell opens recent
activity, with access to the full Activity section.

Common shortcuts are **⌘1** for Overview, **⌘2** for the terminal, **⌃⌘S** for the
sidebar, **⌘⇧U** for Reviews & Usage, and **⌘,** for Settings. Standard editing
commands follow the focused responder.

## Verify

Run the first Xcode build or `bash macos/scripts/bootstrap.sh` to prepare native
dependencies, then run the checks appropriate to your change:

```bash
cargo test --manifest-path crates/craft-backend/Cargo.toml
cargo test --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots

xcodebuild test -project macos/Craft.xcodeproj -scheme Craft \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath macos/.build/xcode \
  -only-testing:CraftTests
```

Swift Testing does not select individual functions through
`-only-testing:CraftTests/someFunctionName`: it can run zero tests and still report
success. Check the executed test count. The backend's `route_contract` test checks
the Swift API paths; terminal tests exercise isolated sockets and fixture shells.

The UI target can be selected separately:

```bash
xcodebuild test -project macos/Craft.xcodeproj -scheme Craft \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath macos/.build/ui-tests \
  -only-testing:CraftUITests
```

Many UI tests require prepared fixture data and `CRAFT_UI_BACKEND_URL`,
`CRAFT_UI_DATA_DIR`, and `CRAFT_UI_PTY_SOCKET`. Some also require
`CRAFT_UI_PTYD_PATH`; real-build coverage is opt-in with `CRAFT_UI_REAL_BUILD=1`.
Read the selected test's setup in [`CraftUITests.swift`](UITests/CraftUITests.swift)
and provide its expected records and files through an isolated Rust backend.
Without the fixtures, tests skip; a successful invocation is not proof of UI
coverage. The old fixture launcher is no longer part of this repository.

[`GhosttySnapshotTests`](GhosttySnapshotTests/Package.swift) is a separate package
for bridge work. It expects a prepared local Ghostty package, selected through
`CRAFT_GHOSTTY_PACKAGE` or the path documented in its manifest. Follow the
[patch guide](patches/ghostty/README.md) when working on that runtime.

### Terminal stress benchmark

Run this only when intentionally measuring terminal behavior, with no concurrent
builds, UI tests, or other benchmark:

```bash
bash macos/scripts/bootstrap.sh
xcodebuild build -project macos/Craft.xcodeproj -scheme CraftTerminalStress \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/.build/terminal-stress
macos/.build/terminal-stress/Build/Products/Release/CraftTerminalStress \
  --seconds 600 --root "$PWD" \
  --helper "$PWD/crates/craft-ptyd/target/release/craft-ptyd" \
  --report /tmp/craft-terminal-stress.json
```

The harness exercises ten sessions and records machine/build metadata,
input-to-parsed-output latency, queues, and process resource measurements. Check
the report and process completion. These measurements do not establish physical
display latency or performance on another machine.

## Direct-distribution packaging

Craft uses direct distribution with bundle identifier `com.alexcding.craft`.
The app is not sandboxed because it orchestrates local CLIs, worktrees, and PTYs.
Local builds use ad-hoc signing; public distribution requires Developer ID signing
and notarization. Packaging tooling requires Python 3.11+.

Build Release and prepare its bundle:

```bash
xcodebuild build -project macos/Craft.xcodeproj -scheme Craft \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath macos/.build/xcode
bash macos/scripts/bundle-backend.sh \
  "$PWD/macos/.build/xcode/Build/Products/Release/Craft.app"
```

The bundle script checks framework resolution, builds the Rust crates, copies the
PTY helper, provider artwork, and dependency licenses, and ad-hoc signs the app.
The backend is linked into the app executable; `Contents/Helpers` contains
`craft-ptyd`, not a separate backend executable. If using another derived-data
location, set `CRAFT_GHOSTTY_PACKAGE` to its Ghostty package checkout so the script
can find dependency licenses.

**Current packaging limitation:** `package-direct.py` rejects all bundled `.js`
and `.mjs` files, including the files required by `Resources/DiffPage`. That check
must be reconciled with the bundled diff renderer before packaging the current
app. Do not remove the diff assets to bypass it. The commands below describe the
packaging interface, not a verified release of the current source.

For a local package, select an output directory that does not already exist:

```bash
python3 macos/scripts/package-direct.py --local \
  --app "$PWD/macos/.build/xcode/Build/Products/Release/Craft.app" \
  --output "$PWD/macos/.build/local-package"
```

For a signed release, use your Developer ID identity and existing notarytool
Keychain profile:

```bash
python3 macos/scripts/package-direct.py \
  --app "$PWD/macos/.build/xcode/Build/Products/Release/Craft.app" \
  --output "$PWD/macos/.build/signed-package" \
  --identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --notary-profile CRAFT_NOTARY
```

The script stages the input bundle and produces `Craft.app`, `Craft.zip`,
`Craft.dmg`, and `release.json` with checksums. Signed mode signs embedded code,
submits for notarization, and staples the app and disk image. It does not install
the app or publish an update feed. Use a fresh output directory for each run.

The bundle script notes missing upstream license files for the pinned
CodeEditLanguages and CodeEditSymbols packages. Resolve those dependency notices
before public distribution. A local package is not evidence of notarization,
update installation, or clean-machine acceptance.

### Native updates and launch at login

Sparkle configuration uses `CRAFT_UPDATE_FEED_URL` and `CRAFT_UPDATE_PUBLIC_KEY`,
mapped to `SUFeedURL` and `SUPublicEDKey` in the app's Info.plist. The updater
requires a Release app, a valid HTTPS feed, and a base64-encoded 32-byte Ed25519
public key. Private signing keys stay outside the repository. Publishing an
appcast and signing update archives are separate release steps.

**Current availability limitation:** `AppUpdater` and
`LoginItemRegistrationPolicy` still check for `Contents/Helpers/craft-backend`,
which the embedded-backend bundle deliberately omits. Those checks must be updated
before updates and new launch-at-login registration can activate in that bundle.
Development builds also keep these features disabled.

An update restart follows the same document-save and terminal-cleanup transaction
as Quit. Cancelling a save cancels termination. See
[data recovery](../docs/DATA-RECOVERY.md) for checkpoints and restoring app data;
worktree files and unsaved editor buffers require separate preservation.
