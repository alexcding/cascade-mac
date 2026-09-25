# Research

Surveyed 2026-09-24 on `main` at `8e195ae`. Every codebase claim cites `file:line`; platform
claims carry a source or are marked UNVERIFIED. Line numbers drift; the symbol names do not.

## A. Backend transport and route surface

**Transport today is loopback-only by construction, with no authentication anywhere.**

| Fact | Where |
|---|---|
| The embedded backend binds `TcpListener::bind((Ipv4Addr::LOCALHOST, 0))` and writes the port to `.server-port` | `crates/craft-backend/src/ffi.rs:119-139` |
| `APIClient.init` rejects any base URL whose host is not `127.0.0.1` / `localhost` / `[::1]`, scheme not `http`, or with a path/query | `macos/Services/Backend/APIClient.swift:80-89` |
| No auth header is ever attached; the router has only cache-control, body-limit and tracing layers | `APIClient.swift:115,135,146`; `lib.rs:197-199` |
| Transport is chosen by `BackendConfiguration.current`: embedded (default), `--backend-path` child process, `--backend-url` external | `macos/Services/Backend/BackendProcess.swift:20-69` |
| Events: HTTP mode reads `GET /api/stream` as SSE via `SSEClient`; embedded mode subscribes over FFI (`craft_backend_subscribe`) and never touches HTTP | `SSEClient.swift:76`; `EmbeddedBackend.swift:88`; `BackendRuntime.swift:91` |
| `ServerEvent` fields: `type, projectId?, id?, event: ActivityEvent?, runId?, cli?, sessionId?, source?, scope?, worktree?, status?, label?, message?, url?` | `SSEClient.swift:3-21` |
| Health handshake checks `service=="craft"`, `protocol==1`, optional `instanceId` | `APIClient.swift:43,104` |

`foreign_origin` (`local.rs:46-56`) is a browser CSRF guard, not authentication: it allows a
request when the `Origin` header is **absent** or loopback. A native client sends no
`Origin`, so it passes. It guards only `get_file`, `list_files`, `put_file`, `launch_target`
(`local.rs:166,206,246,399`), the three Xcode reads (`xcode.rs:757,880,922`), `open_url`
(`integrations.rs:697`), sim-preview start/stop (`sim_preview.rs:137,191`) and warmup
(`warmup.rs:309,325`). Everything else has no check at all, including `git/*`, `worktree*`,
`db`, `poll`, and `webhook/github`, which verifies no signature (`integrations.rs:817-841`).

### Route inventory (from `build_app`, `lib.rs:64-201`)

Read-only, safe to allowlist in phase 1:

| Route | Handler |
|---|---|
| `GET /api/backend/health` | `routes::health` |
| `GET /api/config`, `/api/settings` | `routes::get_config`, `get_settings` — **settings contain `jira_api_token`; do not relay** |
| `GET /api/tabs`, `/api/tasks` | `routes::get_tabs`, `get_tasks` |
| `GET /api/projects`, `/api/projects/{id}`, `/{id}/prs`, `/{id}/jira`, `/{id}/board` | `routes::*` |
| `GET /api/dashboard`, `/api/prs/tray`, `/api/prs/lookup` | `routes::dashboard`, `prs_tray`, `lookup_pr` |
| `GET /api/events`, `/api/logs`, `/api/logs/categories` | `routes::*` |
| `GET /api/stream` (SSE) | `routes::stream` |
| `GET /api/whoami`, `/api/jira/site`, `/api/usage` | — |
| `GET /api/agent/catalog`, `/status`, `/conversation` | `agents::*` |
| `GET /api/automations…`, `/api/cli-tools`, `/api/agent-hooks`, `/api/forwarders` | — |
| `GET /api/worktree*`, `/api/diff`, `/api/git/log|refs|tracked|show|commit-avatars` | `local::*` — read-only git, phase 2 at the earliest |
| `GET /api/file`, `/api/files`, `/api/db`, `/api/detect-repo`, `/api/launch-target`, `/api/xcode/*`, `/api/ide/warmup` | **never relay**: file system / DB dump / host paths |

Mutating, candidates for phase 2:

| Route | Handler | Relay? |
|---|---|---|
| `POST /api/jira/{key}/transition`, `/assign`, `POST /api/jira/search` | `routes::jira_*` | yes |
| `POST /api/prs/viewed`, `PATCH /api/tasks/{id}/pin` | — | yes |
| `POST /api/poll` | `routes::poll` (triggers `gh`/Jira sync) | yes, rate-limited |
| `POST /api/automations/{id}/run` | — | yes |
| `POST/PUT/DELETE /api/tasks`, `/api/projects`, `/api/tabs`, `/api/links`, `/api/config`, `PUT /api/settings/{key}` | — | no in v1 |
| `POST /api/hooks/*`, `POST /webhook/github`, `POST /api/agent-analyze` | `integrations::*` | never |

Dangerous, never relayed: `PUT /api/file`, `POST /api/worktree`, `/api/worktree/remove`,
`POST /api/git/commit|push|discard|switch`, `POST/DELETE /api/agent-hooks/{cli}`,
`POST /api/ide/warmup`. `POST/DELETE /api/sim-preview` is spawn-capable but is exactly what
R3 needs; it is relayed behind its own guard (architecture §5).

Note that "session start/stop" (R2) is not a backend route: sessions are created and
stopped from Swift (`macos/Services/Workspace/SessionOperations.swift`, `SessionRemoval.swift`)
which drive ptyd and the task records. Remote actions on sessions therefore need a Swift-side
command executor (architecture §6).

## B. Simulator preview

| Fact | Where |
|---|---|
| Backend runs `serve-sim --detach -q <udid>` (installed) or `npx -y @expo/serve-sim@0.3.1 --detach -q <udid>`, 120 s timeout | `crates/craft-backend/src/sim_preview.rs:40-56,166-171` |
| The helper answers `{"url","streamUrl","wsUrl","port","device"}`; the backend forwards **only** `{udid, url}` and drops `streamUrl`/`wsUrl`/`port` | `sim_preview.rs:111-121` |
| `url` must match `^http://(127\.0\.0\.1|localhost|\[::1\]):\d+/?$`; Swift re-checks loopback before loading | `sim_preview.rs:117`; `macos/Services/Workspace/SimulatorPreview.swift:33-37` |
| The Mac renders the helper's **own web page** in a `WKWebView`; that page does the MJPEG and the touch WebSocket itself. Craft has no native stream or input code | `SimulatorPreview.swift:100-121`; `Scenes/Workspace/SimulatorPanelView.swift:14` |
| Start trigger: a build reaching `atShell` on a simulator destination calls `preview.show(udid:)` → `POST /api/sim-preview` | `Services/Workspace/BuildWorkspace.swift:216-218`; `SimulatorPreview.swift:20-26` |
| Since `39d557b`, `SimulatorPreviewModel.active` follows whether the session is on screen; inactive unloads the page (`loadHTMLString("")`) but the helper keeps running | `SimulatorPreview.swift:94-96,127-138` |
| Retiring the model leaves the helper running ("another session may be showing the same device"); `DELETE /api/sim-preview` runs `serve-sim --kill` for every helper, called from `prepareToTerminate` | `SimulatorPreview.swift:141-142`; `sim_preview.rs:190-203`; `App/AppViewModel.swift:1423` |
| Needs Node ≥ 20; missing Node maps to the `MISSING` precondition and the "Open Integrations" UI | `sim_preview.rs:32-33,66-76,206-215`; `SimulatorPreview.swift:192-195` |
| Which simulator is live is **Swift-side state** (`BuildWorkspace` / `SimulatorPreviewModel.state == .live`); the backend does not track it | `SimulatorPreview.swift`, `BuildWorkspace.swift` |

## C. `@expo/serve-sim` 0.3.1 (verified from the npx cache, `~/.npm/_npx/…/@expo/serve-sim`)

| Fact | Where |
|---|---|
| The helper listens on `127.0.0.1` by default; `0.0.0.0`/`::` are normalised back to loopback for URL emission | `src/state.ts:60-63`; `src/middleware.ts:1067` |
| The page **rewrites** `127.0.0.1` in stream/WS URLs to the request's `Host` hostname "so LAN/tunnel viewers can still reach the separate helper port" | `src/middleware.ts:479-504` |
| Stream tuning flags: `--mjpeg-fps 1-120`, `--mjpeg-quality 0.05-1`, `--max-dimension`, `--codec auto|h264|mjpeg`, `--transport http|webrtc`, `--video-bitrate`, `--video-fps` | `README.md:105-120` |
| Ports: preview default 3200, helper default 3100 (`-p`) | `README.md:93` |
| Touch WS messages: `{"type":"begin"|"move"|"end","x":0-1,"y":0-1,"edge":0-4}`; two-finger form uses `x1,y1,x2,y2`. Keyboard/rotate message names UNVERIFIED | upstream `gestures.md` (web research) |

Consequence: relaying the helper with the `Host` header preserved makes the page, its
stream and its WebSocket all point back at the relay. The phone needs no protocol knowledge.
The Mac must start forwarding `port` (or the relay must learn it) so the relay knows where
the helper is; today that field is discarded (`sim_preview.rs:120`).

## D. Terminal (ptyd)

| Fact | Where |
|---|---|
| Unix socket at `$CRAFT_PTYD_SOCK`, else a private `$TMPDIR/craft-ptyd.sock`, else `/tmp/craft-<uid>/craft-ptyd.sock` (0700) | `crates/craft-ptyd/src/lib.rs:90-119`; `macos/Services/Terminal/PtydHost.swift:24-54` |
| Framing: newline-delimited JSON, no length prefix, 2 MiB frame cap on the Swift side | `PtyProtocol.swift:194-211`; `lib.rs:1350-1362` |
| Ops: `hello, create, write, resize, kill, killAll, list, attach, flow, foreground, appearance, snapshotBegin/Read/End`; a request without `id` is fire-and-forget | `lib.rs` `handle()`; `PtydClient.swift:71-98` |
| Protocol 2: `hello{dataEncoding:"base64", eventScope:"attached", …}` negotiates exact-byte transport and per-connection event scope; Swift refuses mismatches | `lib.rs:69,1213-1238`; `PtyProtocol.swift:56-126` |
| Events: `{"ev":"data","id","bytes","seq"}`, `{"ev":"exit",…}`, plus resize/geometry/appearance/state | `PtyProtocol.swift:145-158` |
| **Several clients may attach to one terminal**; attach subscribes then returns the ring tail `{bytes, seq, live, truncated}` with `RING_MAX = 256 KiB`; the client then hears `seq >` events with no gap | `lib.rs:70,1158-1182`; `tests/protocol.rs:116-118` |
| Backpressure per client: 8 MiB outbox, stalled 60 s → dropped; a terminal pauses reads while any client owes more than `BACKLOG_HIGH` | `lib.rs:32-37` |
| Snapshots (`terminal-snapshots`) require the exact `craft_vt::GHOSTTY_REVISION` at hello and are for restoring a full screen; ring replay is the normal attach path | `lib.rs:1232-1237`; `PtySnapshot.swift:4-44` |
| Auth is filesystem ownership only (uid match, mode `& 0o077 == 0`); no token in the protocol | `lib.rs:108-119`; `PtydHost.swift:38-54` |
| Daemon exits after 30 s idle with no terminals and no clients | `lib.rs:71,1184-1195` |
| GhosttyTerminal is pinned to `alexcding/ghostty-terminal-spm` `1.6.20260909-taskhub.1`; the pbxproj has no iOS settings at all | `macos/Craft.xcodeproj/project.pbxproj:753-758` |

Consequence: a network bridge that forwards frames verbatim and filters ops is enough. The
phone can use ring replay and skip snapshots (which would also pin it to the Ghostty revision).

## E. Platform facts (web research, 2026-09-24)

### E-a. CloudKit

| Question | Answer | Source |
|---|---|---|
| Works in a Developer ID (non-App Store) macOS app | Yes | developer.apple.com/developer-id |
| Works in an ad-hoc, no-team build | **No**: the iCloud entitlement needs a provisioning profile from a team | CloudKit Quick Start, Testing Your App |
| Paid Developer Program required for production use | Effectively yes; free accounts can iterate in Xcode but not deploy (partially UNVERIFIED) | developer.apple.com/icloud/ck-tool |
| Private database readable by the same Apple ID on another device with no sharing step | Yes | CloudKit docs (private vs shared database) |
| `CKSyncEngine` on macOS 14 / iOS 17 | Yes, iOS 17.0+/macOS 14.0+; Apple's recommended sync API. We only need a few records so plain `CKDatabase` fetch/save is enough | developer.apple.com/documentation/cloudkit/cksyncengine |
| Silent push on record change | Yes via `CKQuerySubscription`/`CKDatabaseSubscription`; needs Background Modes → Remote notifications; database subscriptions need a custom zone; a force-quit app is not woken | developer.apple.com/forums/thread/130104 |

### E-b. Network and TLS on Apple platforms

| Question | Answer | Source |
|---|---|---|
| TLS-PSK via `sec_protocol_options_add_pre_shared_key` | Supported but **TLS 1.2 ciphersuites only** | developer.apple.com/forums/thread/688508 |
| rustls TLS 1.2 PSK | Not available (rustls supports TLS 1.3 resumption PSK only) → PSK ruled out; use certificate pinning | rustls docs (planner's knowledge, UNVERIFIED for the current release) |
| `WKWebView` / `URLSession` can accept a pinned self-signed certificate | Yes: `urlSession(_:didReceive:)` / `webView(_:didReceive:completionHandler:)` server-trust challenge | Apple docs |
| `NWListener.Service` Bonjour advertising; iOS browse needs `NSLocalNetworkUsageDescription` + `NSBonjourServices` and prompts the user | Yes | developer.apple.com/forums/thread/653316 |
| `NWBrowser` in the background | Effectively no | developer.apple.com/forums/thread/772637 |
| `URLSession` parses `multipart/x-mixed-replace` (MJPEG) | **No**, must be parsed by hand | developer.apple.com/forums/thread/16682 |
| `URLSessionWebSocketTask` | iOS 13+/macOS 10.15+ | Apple docs |

### E-c. Terminal renderers for iOS

| Option | Status |
|---|---|
| libghostty on iOS | Community XCFrameworks with iOS slices exist (`Lakr233/libghostty-spm`); `madeye/gterm` ships on it. Our own `ghostty-terminal-spm` has no iOS slice today (UNVERIFIED from the package manifest) |
| SwiftTerm | Maintained, UIKit `iOSTerminalView`, latest tag v1.20.0 |

### E-d. Tailscale

The Tailscale iOS app is a system VPN (`NEPacketTunnelProvider`); any app's sockets to a
100.x address traverse it with no per-app integration. So publishing the Mac's tailnet IP as
one more candidate address gives off-network access for free when both devices run Tailscale.
Source: tailscale.com/docs/features/exit-nodes.

## F. Signing, settings, secrets, notifications

| Fact | Where |
|---|---|
| Bundle id `com.alexcding.craft`, `MACOSX_DEPLOYMENT_TARGET 14.0`, `CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Manual`, **no `DEVELOPMENT_TEAM`**, `ENABLE_APP_SANDBOX = NO` | `macos/Resources/Configs/Shared.xcconfig:11,15,26-28` |
| `Craft.entitlements` exists and is an empty dict | `macos/Resources/Configs/Craft.entitlements` |
| Packaging: `macos/scripts/package-direct.py` signs with a supplied Developer ID, notarises, staples, builds a DMG; no update feed is published; Sparkle public key in `Release.xcconfig:12` | `macos/scripts/package-direct.py` |
| Settings are one KV table `settings(key TEXT PRIMARY KEY, value TEXT)` in `craft.db`; `jira_api_token` is plaintext there; **no Keychain code exists** in app or backend | `crates/craft-backend/src/schema_durable.sql:2`; `macos/Services/Settings/SettingsService.swift:3-40` |
| "Agent needs input" is `AgentTurnTracker.idle` = `streamAvailable && betweenTurns && pending == nil`, fed by `agent-turn-start/done` hook events; surfaced only as a sidebar badge via `TerminalSession.agentIdle` | `macos/Services/Terminal/AgentTurnTracker.swift:50,75-83`; `TerminalSession.swift:22`; `AppViewModel.swift:1257-1258` |
| Notifications are local `UNUserNotificationCenter` only, for server `ActivityEvent`s (`pr_opened/merged/closed`, `jira_*`, `sync_failed`, `automation_*`); no APNs, no agent-idle event | `macos/Services/Notifications/NotificationModels.swift:56-70`; `MacNotificationDelivery.swift:29-33` |
| Review waiting = `awaitingMyReview` / `category` in `github.rs` (tray bronze) | `crates/craft-backend/src/github.rs:313` |

Consequences: (1) CloudKit needs a team and entitlements that do not exist yet; (2) the host
secret has nowhere better than `craft.db` today unless Keychain code is added; (3) agent-idle
is Swift-side, so the Mac app (not the backend) is the natural writer of `Alert` records.
