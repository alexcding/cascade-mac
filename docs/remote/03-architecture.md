# Architecture

```
 iPhone (Craft Remote)                          Mac (Craft)
 ┌──────────────────────┐                      ┌────────────────────────────────────────┐
 │ SwiftUI views        │                      │ Swift                                  │
 │ RemoteClient ────────┼── HTTPS/SSE/WS ─────►│  RemoteListener (Rust, port N, TLS)    │
 │  (pinned cert,       │   on LAN/tailnet     │   ├─ auth + allowlist ─► axum router   │
 │   bearer secret)     │                      │   ├─ /sim/{udid}/… ───► serve-sim 3100 │
 │ WKWebView ───────────┼── relayed page ─────►│   └─ /pty (WS) ───────► ptyd socket    │
 │ CloudKit (private DB)│◄─ Host, Alert ──────►│  RemotePairing (Swift, CloudKit)       │
 └──────────────────────┘   push on change     │  RemotePresence, RemoteCommands (Swift)│
                                               └────────────────────────────────────────┘
```

Two channels. **CloudKit** carries the pairing record and small alerts; it is slow (seconds)
and rate-limited but reaches the phone anywhere and wakes it. **The direct connection**
carries everything live; it needs the phone and Mac to be on the same network (LAN or
tailnet).

## 1. Pairing through iCloud

### Records (CloudKit private database, custom zone `craft`)

`Host` — one per Mac, record name = the Mac's stable instance id.

| Field | Type | Meaning |
|---|---|---|
| `name` | String | e.g. "Alex's MacBook Pro" |
| `instanceId` | String | matches `/api/backend/health` `instanceId` so the phone can verify it reached the right Mac |
| `endpoints` | [String] | candidate `host:port` list: every non-loopback IPv4/IPv6 of the Mac, Tailscale address included, refreshed by `NWPathMonitor` |
| `certFingerprint` | String | SHA-256 of the listener's certificate SPKI, hex |
| `secret` | String | 32 random bytes, base64url; the bearer token |
| `generation` | Int | bumped on rotate; the phone drops cached state when it changes |
| `updatedAt` | Date | staleness display on the phone |

`Alert` — appended by the Mac, read and deleted by the phone.

| Field | Meaning |
|---|---|
| `kind` | `agentIdle`, `reviewRequested`, `syncFailed` |
| `title`, `body`, `deepLink` | what to show and where a tap goes (`craft://…`, reusing `AppCoordinator+Routing.swift` routes) |
| `hostId`, `createdAt` | |

### Flows

- **Enable (Mac):** Settings → Remote → toggle on. Swift asks the backend to enable the
  listener (`POST /api/remote/enable`) which generates the certificate and secret on first
  use, binds the port, and returns `{port, certFingerprint, secret, instanceId}`. Swift
  gathers the addresses and saves the `Host` record. Every path change re-saves `endpoints`.
- **Pair (phone):** on launch, fetch `Host` records from the private database. Show them as
  a list; there is nothing to type. Being signed into the same Apple ID *is* the
  authorisation; CloudKit's private database is not readable by any other account.
- **Connect (phone):** try every endpoint concurrently, `GET /api/backend/health` with the
  bearer secret and pinned certificate; keep the first that answers with the expected
  `instanceId`. Cache the winner; fall back to the race when it fails.
- **Rotate / revoke (Mac):** Settings → Remote → "Forget all phones" regenerates the secret
  and certificate, bumps `generation`, re-saves `Host`. Disabling deletes the record and
  stops the listener.

Why one shared secret rather than per-device tokens: it keeps v1 to one record and no
device registration flow. Per-device tokens (N3) are a later refinement: a `Device` record
per phone holding a public key, and the listener accepting a signed challenge.

### Trust model

- The phone verifies the Mac by certificate fingerprint (from CloudKit) and `instanceId`.
- The Mac verifies the phone by the bearer secret (from CloudKit) on every request.
- CloudKit itself is the root of trust; the assumption is that whoever can read the user's
  private database is the user. That is the same assumption as iCloud Keychain.
- Nothing is exposed on the network unless Remote is enabled, and then only the allowlist.

## 2. The remote listener (Rust, `crates/craft-backend/src/remote/`)

A second axum server, started only when enabled, bound to `[::]:0` (or a stored port so the
CloudKit record stays valid across restarts), served through `axum-server` with rustls.

| Piece | Design |
|---|---|
| Certificate | `rcgen` self-signed, 10-year validity, CN `craft-<instanceId>`; PEM stored in `craft.db` settings (`remote_cert`, `remote_key`), secret in `remote_secret`. Same trust level as `jira_api_token` today; Keychain is an open question |
| Auth layer | Tower middleware: constant-time compare of `Authorization: Bearer` with the secret; `401` otherwise. Applied to every route including the relays. The sim relay additionally accepts a cookie minted by `POST /sim/{udid}/ticket` because `WKWebView` cannot add headers to subresource requests |
| Allowlist | An explicit `Router` that maps each permitted path to the same handler function used in `build_app`. It does **not** nest or fall through to the loopback router. Adding a route to the phone is a deliberate one-line change plus a `route_contract`-style test listing what is served |
| Origin | The relay strips any `Origin` header before invoking a handler so `foreign_origin` cannot be reasoned about from the phone side; the allowlist is the boundary |
| Rate limits | `POST /api/poll` and the ticket endpoint are limited (one per 10 s per client) |
| Events | `GET /api/stream` is served from the same broadcast channel as the loopback SSE |
| Control routes (loopback only, in `build_app`) | `GET /api/remote` (status), `POST /api/remote/enable`, `/disable`, `/rotate`, `PUT /api/remote/presence`. Added to `Routes.swift` and the route contract |

Why not `0.0.0.0` with the existing router plus a middleware: the existing router has ~90
routes with file, git and DB reach and no authentication; a single missed path is a shell
on the user's Mac. An allowlist fails closed.

## 3. Presence: what is on the Mac's screen

The backend does not know which simulator is live or which session is shown (research §B,
§D). The Mac app pushes a small presence document whenever it changes:

```json
{ "sessions": [{ "id": "…", "title": "…", "worktree": "…", "termId": "pty…", "agentIdle": true }],
  "simulators": [{ "udid": "…", "helperPort": 3100, "sessionId": "…", "live": true }],
  "selection": { "sessionId": "…" } }
```

`PUT /api/remote/presence` from Swift (a `RemotePresence` service observing
`AppViewModel` state), `GET /api/remote/presence` on the remote listener, and a `presence`
event on the stream when it changes. This is the phone's home screen data for sessions and
the simulator picker; PRs and Jira come from the existing snapshot routes.

For `helperPort`, `sim_preview.rs` must stop dropping the helper's `port` (`parse_detach`,
`sim_preview.rs:111-121`) and return it alongside `{udid, url}`.

## 4. Actions from the phone

Two kinds:

- **Backend actions** go straight to allowlisted routes: Jira transition/assign, mark PR
  viewed, pin a task, run an automation, poll.
- **App actions** are things only Swift can do today: start or stop a session, reply to an
  agent, open a session on the Mac. These go through `POST /api/remote/command` on the
  remote listener, which enqueues a `Command` `{id, kind, args}` and broadcasts a
  `remote-command` event. A Swift `RemoteCommands` service handles it via the same code
  paths as the UI (`SessionOperations`, `SessionRemoval`, the terminal input queue) and
  answers with `POST /api/remote/command/{id}/result` on the loopback router. The phone
  polls or watches the stream for the result. This keeps "views present what the API
  returns" true on the phone and reuses the Mac's own session logic instead of duplicating
  it in Rust.

"Reply to an agent" is `write` on the session's terminal; phase 2 does it through the
command path (Swift's `TerminalInputQueue`), phase 4 can do it directly over the PTY bridge.

## 5. Simulator relay

Route: `/sim/{udid}/{*path}` on the remote listener, HTTP and WebSocket upgrade, forwarded
to `127.0.0.1:{helperPort}/{path}` from presence. Rules:

- Preserve the incoming `Host` header so serve-sim rewrites `streamUrl`/`wsUrl` to the
  relay (`src/middleware.ts:479-504`). Everything the page then loads comes back through
  the same authenticated relay.
- Auth by cookie: the phone calls `POST /sim/{udid}/ticket` with the bearer secret, gets a
  short-lived (`Max-Age=3600`, `Secure`, `HttpOnly`, `Path=/sim/`) cookie, and loads the
  page in a `WKWebView` whose navigation delegate accepts the pinned certificate.
- Starting a stream from the phone: `POST /api/sim-preview` is allowlisted (phase 3) so a
  phone can bring a helper up for a booted device; stopping is only through the Mac
  (`DELETE` kills every helper, `sim_preview.rs:190-203`, too blunt for a remote).
- Bandwidth: on a tailnet over cellular, start the helper with `--mjpeg-fps 15
  --mjpeg-quality 0.5 --max-dimension 900`; this is a Settings → Remote choice, not a
  per-request one, because the helper is shared with the Mac's own view.
- The Mac's own `active` gating is untouched: unloading the Mac's page never stops the
  helper, so a phone viewer is unaffected. The helper is stopped only on Quit.

Input works because the page's own gesture handling runs in the phone's `WKWebView`, and
pointer events map from touch. Whether the page's UI is usable at phone width is an open
question to check in phase 3; the fallback is a native viewer speaking the WS gesture
protocol (`begin/move/end`, research §C) over an `<img>`-less MJPEG parser, which is more
work and why it is the fallback.

## 6. Terminal bridge (phase 4)

Route: `GET /pty` WebSocket on the remote listener. The bridge opens one Unix-socket
connection to ptyd per WebSocket, sends its own `hello` (protocol 2, base64, `eventScope:
"attached"`, no snapshot revision), and then forwards frames both ways with an op filter:

| Op | Allowed |
|---|---|
| `list`, `attach`, `write`, `resize`, `flow`, `foreground` | yes |
| `create`, `kill`, `killAll`, `appearance`, `snapshot*`, `hello` | no (`hello` is the bridge's own) |

Frame size and outbox limits come from ptyd itself (2 MiB frames, 8 MiB outbox, stalled
clients dropped), so a slow phone cannot stall the Mac's terminals.

Phone side: a `PtyProtocol`-compatible client over `URLSessionWebSocketTask` (the Swift
types in `PtyProtocol.swift` move to the shared package) and SwiftTerm as the renderer.
Attach uses ring replay; if `truncated` is true the phone clears the screen and goes live
rather than fetching a snapshot. Resize is not sent by the phone (it would fight the Mac's
geometry); the phone renders the Mac's `cols/rows` and scrolls.

## 7. Alerts (phase 2)

The Mac app is the writer because the two signals already live there:

- `agentIdle` becoming true for a session that is not selected → `Alert{kind: agentIdle}`.
  This is the same condition as the sidebar badge (`AppViewModel.swift:1257`).
- `awaitingMyReview` gaining a PR → `Alert{kind: reviewRequested}`; `sync_failed` → alert.

The phone holds a `CKQuerySubscription` on `Alert` with `shouldSendContentAvailable` and a
visible notification payload; iOS shows it without the app running. Tapping opens the
session or PR screen; the phone deletes the record. Alerts older than 24 h are pruned by
the Mac. Rate: one record per transition, debounced 5 s, which stays far below CloudKit's
limits.

## 8. Code layout

| Where | What |
|---|---|
| `crates/craft-backend/src/remote/{mod,listener,auth,allowlist,sim_relay,pty_bridge,presence,commands}.rs` | the listener |
| `crates/craft-backend/src/lib.rs` | control routes; `route_contract` extended with a `remote_contract` listing the allowlist |
| `macos/Services/Remote/{RemotePairing,RemotePresence,RemoteCommands,RemoteAlerts}.swift` | CloudKit, presence push, command executor, alert writer |
| `macos/Scenes/Settings/RemoteSettingsView.swift` | enable, status, endpoints, "Forget all phones", stream quality |
| `packages/CraftKit/` (new SPM package) | `APIClient` (with a `RemoteTransport`), `Routes`, `SSEClient`, models, `PtyProtocol`, `ServerEvent`. Both apps depend on it |
| `ios/CraftRemote.xcodeproj` | the phone app: Pair, Home (sessions + presence), Project (PRs/Jira), Session (status, reply), Simulator, Terminal |

`APIClient` today refuses non-loopback URLs (`APIClient.swift:80-89`); the shared version
takes a `Transport` that owns the base URL, the bearer header and the pinned trust, and the
loopback validation moves into the Mac's `LoopbackTransport` so nothing on the Mac changes
behaviour.
