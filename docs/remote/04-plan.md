# Plan

Estimates are working days for one engineer, judged from the surveyed surface in
[02-research.md](02-research.md). No code has been sized; treat them as ±50 %.

## Phase 0 — Signing and containers (blocking, ~1 day plus Apple's lead time)

| # | Item | Notes |
|---|---|---|
| 0.1 | Apple Developer Program team | Required for the iCloud entitlement (research §E-a). Decide: personal team vs organisation |
| 0.2 | Mac app: `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE = Automatic` for dev, Developer ID for release; add `com.apple.developer.icloud-services = [CloudKit]` and `com.apple.developer.icloud-container-identifiers = [iCloud.com.alexcding.craft]` to `Craft.entitlements`; `aps-environment` for the alert subscription | Keep `ENABLE_APP_SANDBOX = NO`; CloudKit does not need the sandbox |
| 0.3 | CloudKit container `iCloud.com.alexcding.craft`, custom zone `craft`, record types `Host` and `Alert`, deployed to production via CloudKit Console or `cktool` | Development environment first |
| 0.4 | iOS app id `com.alexcding.craft.remote` with the same container, push capability | |
| 0.5 | Confirm `package-direct.py` still notarises with the new entitlements | It already takes a Developer ID identity |

Exit: a dev build of the Mac app can save and read a record in the private database.

## Phase 1 — Read-only remote (~5 days)

Backend (Rust):

| # | Item |
|---|---|
| 1.1 | `remote/` module: `rcgen` certificate + secret generation, storage in `craft.db` settings, `axum-server` rustls listener on a stored port, bearer middleware, allowlist router with the read-only routes from research §A (minus `settings`, `config`, `file*`, `db`, `xcode`, `warmup`, `launch-target`, `detect-repo`) |
| 1.2 | Control routes `GET /api/remote`, `POST /api/remote/enable|disable|rotate`, `PUT/GET /api/remote/presence`; `Routes.swift` + `route_contract` updated; a `remote_contract` test asserting the allowlist |
| 1.3 | `presence` event on the broadcast channel |
| 1.4 | Tests: unauthenticated → 401; allowlisted route answers; a non-allowlisted route that exists on the loopback router → 404 on the remote listener; TLS handshake with the fingerprint; `foreign_origin`-guarded route not reachable |

Mac (Swift):

| # | Item |
|---|---|
| 1.5 | `RemotePairing`: enable/disable/rotate, `Host` record save, `NWPathMonitor`-driven endpoint refresh |
| 1.6 | `RemotePresence`: observe sessions, selection, live simulators (from `SimulatorPreviewModel.state`) and push |
| 1.7 | `RemoteSettingsView` in the Settings scene: toggle, status, endpoints, "Forget all phones" |
| 1.8 | Extract `packages/CraftKit` (APIClient with `Transport`, Routes, SSEClient, models). Mac behaviour unchanged; `CraftTests` still pass |

Phone (Swift, new):

| # | Item |
|---|---|
| 1.9 | `ios/CraftRemote`: CloudKit fetch of `Host`, endpoint race, pinned-certificate `URLSession`, bearer |
| 1.10 | Screens: Pair (host list), Home (sessions from presence + review count), Project (PRs with CI, Jira), Session (status, recent activity). Live via SSE while foregrounded |

Exit: on the same Wi-Fi, the phone shows the dashboard and session list with no setup
beyond signing into iCloud. Verified by a Mac-side test suite plus a manual checklist.

## Phase 2 — Actions and alerts (~4 days)

| # | Item |
|---|---|
| 2.1 | Allowlist the phase-2 mutating routes (Jira transition/assign/search, PR viewed, task pin, automation run, rate-limited poll) |
| 2.2 | `POST /api/remote/command` + result route + `remote-command` event; Swift `RemoteCommands` executor for `startSession`, `stopSession`, `replyToAgent`, `showSession` using `SessionOperations` / `SessionRemoval` / `TerminalInputQueue` |
| 2.3 | `RemoteAlerts` writer for `agentIdle`, `reviewRequested`, `syncFailed`; pruning |
| 2.4 | Phone: `CKQuerySubscription` on `Alert`, notification tap deep links, action buttons on Session and PR screens, reply composer |
| 2.5 | Tests: command round-trip through a fake executor; alert debouncing; allowlist contract updated |

Exit: from the phone, transition a Jira ticket, stop a session, reply to an agent; the phone
gets a notification when an agent goes idle with the app closed.

## Phase 3 — Simulator (~3 days)

| # | Item |
|---|---|
| 3.1 | `sim_preview.rs`: return `port` alongside `{udid, url}`; Swift ignores the new field |
| 3.2 | `sim_relay`: HTTP + WebSocket proxy to `127.0.0.1:{helperPort}`, `Host` preserved, ticket cookie |
| 3.3 | Allowlist `POST /api/sim-preview` behind a presence check (the udid must be a device the Mac has booted) |
| 3.4 | Settings → Remote: stream quality preset passed as `--mjpeg-fps/--mjpeg-quality/--max-dimension` when the helper is started |
| 3.5 | Phone: Simulator screen = `WKWebView` with pinned trust + ticket cookie; picker from presence |
| 3.6 | Check serve-sim's page at phone width; if unusable, native viewer (MJPEG parser + gesture WS) as fallback (+3 days) |

Exit: the phone shows and drives the simulator the Mac is streaming.

## Phase 4 — Terminal (~5 days)

| # | Item |
|---|---|
| 4.1 | `pty_bridge`: WebSocket ↔ ptyd Unix socket, own `hello`, op filter, per-connection lifetime tied to the WebSocket |
| 4.2 | Move `PtyProtocol` types into `CraftKit`; phone `PtyBridgeClient` over `URLSessionWebSocketTask` |
| 4.3 | Phone Terminal screen with SwiftTerm, ring-replay attach, read-only first, then keyboard input and an accessory bar (Esc, Ctrl, arrows, Tab, Enter) |
| 4.4 | Tests in `craft-ptyd` style: filtered op rejected; attach replay through the bridge matches direct attach |

Exit: live terminal of any session on the phone with input.

## Later

- Per-device tokens and a device list in Settings (N3).
- Bonjour advertising for instant LAN discovery without waiting on CloudKit propagation.
- Keychain storage for the secret and key (see open questions).
- H.264/WebRTC transport for the simulator on slow links (`--codec h264 --transport webrtc`
  is supported by serve-sim; the relay would need to pass ICE traffic, which is why it is
  deferred).

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| No developer team / entitlement provisioning drags on | Medium | Phase 0 is first and small; everything else can be built against a dev container |
| CloudKit propagation delay makes first pairing feel slow (seconds to a minute) | Medium | Phone shows "Looking for your Macs…" with a manual refresh; Bonjour later |
| The listener exposes something it should not | Low with an allowlist, high without | Allowlist + contract test + auth on every route + no `Origin` semantics |
| serve-sim's page is not usable at phone width | Medium | 3.6 fallback |
| serve-sim changes its URL rewriting in a later version | Low | Version is pinned (`sim_preview.rs:30`); bump deliberately |
| Ghostty snapshot revision pinning leaks onto the phone | Low | The bridge never negotiates snapshots; ring replay only |
| Address changes (DHCP, sleep/wake) leave a stale `Host` record | Medium | `NWPathMonitor` re-save + endpoint race on the phone + `instanceId` check |
| `craft.db` holds a bearer secret in plaintext | Accepted for v1 | Same as `jira_api_token` today; Keychain later |

## Open questions

1. **Team:** personal or organisation Apple Developer account? It decides the container
   name and who can build the iOS app.
2. **Secret storage:** `craft.db` settings (consistent with today) or a first Keychain
   wrapper? Keychain also gives free iCloud Keychain sync, which could even replace the
   `secret` field in the `Host` record.
3. **Dev builds without a team:** local ad-hoc builds cannot use CloudKit. Do we want a
   debug-only pairing fallback (paste the `Host` JSON), or accept that Remote only works in
   team-signed builds?
4. **Port:** fixed (e.g. 27271, stored) so the CloudKit record survives restarts, or
   ephemeral with a re-save on every start? Fixed is simpler; the plan assumes fixed.
5. **Stop from the phone:** `DELETE /api/sim-preview` kills every helper. Is a per-udid stop
   worth adding to `sim_preview.rs`, or is stop Mac-only?
6. **Tailscale:** document it as the supported off-network path, or leave it unmentioned
   until someone asks?

## How to start

Phase 0 needs the team decision. Phase 1.1–1.4 (Rust listener, tests) and 1.8 (`CraftKit`
extraction) do not depend on Apple at all and can start now on this branch.
