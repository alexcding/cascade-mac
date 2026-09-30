# Remote session control from iPhone — plan

Status: **superseded by [06-chat-mirror.md](06-chat-mirror.md)**, which mirrors the chat through
CloudKit instead of streaming the terminal over a direct connection. Kept for its reasoning.
Written 2026-09-29 against `main` at `b62845c` (Cascade naming).
This supersedes the pairing and scope parts of documents 01–04. It keeps their listener,
allowlist and ptyd-bridge decisions, and drops the dashboard, Jira, simulator and CloudKit
parts.

## Goal

From an iPhone signed into the same Apple ID as the Mac:

1. See the Mac's agent sessions.
2. Open one and watch its terminal output live.
3. Type into it: text, Enter, Esc, Tab, Ctrl-C and arrows.
4. Answer an agent's tool-permission prompt (Allow/Deny). This is optional and last.

Setup is two steps. Turn on **Settings → Remote** on the Mac, then open the app on the
phone. Nothing is typed, scanned or copied.

Out of scope for this plan: dashboard, PRs, Jira, the simulator, starting or stopping
sessions from the phone, file edits, alerts when the phone app is closed, and access
without a direct route (LAN or Tailscale).

## The one idea: iCloud KVS finds the Mac, a direct socket carries the session

`NSUbiquitousKeyValueStore` (iCloud key-value store, "iCloud defaults") syncs small keys
between apps that share a KVS identifier on one Apple ID. It suits the rendezvous. It is
the wrong channel for session data:

| Property of KVS | Consequence |
|---|---|
| Propagation takes seconds to minutes and Apple throttles frequent writers | Unusable for terminal bytes or keystrokes |
| 1 MB total, 1024 keys | Fine for a few host and device records |
| No push, no background wake; `didChangeExternallyNotification` fires only while the app runs | No alerts through KVS |
| Last writer wins per key | One key per record, never a shared dictionary |

So:

- **KVS carries only public, slow-changing records.** The Mac publishes where it listens
  and its TLS certificate fingerprint. Each phone publishes its device public key.
  **No secret goes into KVS.**
- **A direct TLS WebSocket from the phone to the Mac carries everything live.** It runs
  over the same Wi-Fi, or over Tailscale if both devices have it, since a `100.x` address
  is just another endpoint.

```
 iPhone app                        iCloud KVS                        Mac (Cascade)
 ──────────                        ──────────                        ─────────────
 device.<id> = pubkey  ───────────►  (sync)  ◄──────────  host.<instanceId> = endpoints,
                                                          port, cert SHA-256
        │                                                            │
        └──── wss://<endpoint>:<port>/remote/ws  (pinned cert) ─────►│ remote listener (Rust)
              challenge → P-256 signature → session list,            │   ├─ ptyd bridge (Unix socket)
              attach/output/input, permission cards                  │   └─ app state via broadcast
```

## Pairing and trust

**KVS records** (identifier `$(TeamIdentifierPrefix)com.alexcding.cascade`, set in both
apps' entitlements):

| Key | Value | Written by |
|---|---|---|
| `remote.v1.host.<instanceId>` | `{name, instanceId, port, endpoints:[ip…], certSHA256, protocol:1, updatedAt}` | Mac, only when something changes |
| `remote.v1.device.<deviceId>` | `{name, publicKey (P-256, x9.63 base64), addedAt}` | Phone, once |

**Flow**

1. **Mac enables Remote.**
   - The backend creates or loads a self-signed certificate (`rcgen`) and starts the
     listener.
   - Swift reads `GET /api/remote/status` (port, fingerprint, endpoints) and writes the
     host record.
   - `NWPathMonitor` rewrites the record when interfaces change.
2. **Phone launches for the first time.**
   - It creates a P-256 key in the Secure Enclave (CryptoKit) and writes its device record.
3. **Mac sees a new device record.** Swift shows the prompt "Allow ‘<device name>’ to control
   sessions?" once. It pushes approved keys to the backend (`PUT /api/remote/devices`),
   stored in `cascade.db`.
4. **Phone connects.**
   - It reads the host records and races every endpoint (3 s each).
   - It pins the certificate by SHA-256.
   - The Mac sends a nonce. The phone signs `nonce ‖ instanceId ‖ deviceId`, and the Mac
     verifies it with the `p256` crate against approved keys only.

**Why this shape**

- No bearer secret lives in iCloud. Revoking one phone means deleting its key on the
  Mac, and that removes the old plan's "rotate one shared secret" limitation.
- The Mac approval in step 3 limits what a compromised iCloud account can do. An attacker
  can publish a key, but it does nothing until someone clicks Allow on the Mac.
- The trust root is otherwise the same as the CloudKit design: the Apple ID.

## The remote listener (backend, `crates/cascade-backend/src/remote/`)

The decisions below are kept from `03-architecture.md`:

- **Server:** a second axum server on `[::]:<port>` using `axum-server` and rustls. It runs
  only while Remote is enabled.
- **Port:** fixed, proposed 27271, so the host record rarely changes. It falls back to
  ephemeral if the port is taken.
- **Routes:** its own router, which **fails closed**. It serves `GET /remote/health` and
  `GET /remote/ws`, and nothing else. It never nests or falls through to the loopback
  router, since that router has about 90 routes and no auth.
- **Auth:** the challenge is the first WebSocket exchange. Nothing else is accepted
  before it. Failed attempts are rate-limited per IP.
- **Control routes** on the loopback router, where the app lives:
  - `GET /api/remote/status`
  - `POST /api/remote/enable` and `POST /api/remote/disable`
  - `PUT /api/remote/devices`
  - `PUT /api/remote/presence`

  Each goes in `Routes.swift` too, and `route_contract` checks them.

The backend stays Apple-free. KVS, `NWPathMonitor` and the Allow prompt are Swift
(`macos/Services/Remote/`).

### WebSocket protocol (newline JSON, versioned)

| Direction | Message | Backed by |
|---|---|---|
| → phone | `sessions {items:[{taskId, title, project, cli, terminalId, agentState, cols, rows}]}` | presence pushed by Swift (below) |
| phone → | `attach {terminalId}` / `detach` | ptyd `attach` (ring replay, `seq`) |
| → phone | `output {terminalId, bytes(base64), seq}`, `exit {…}` | ptyd `data` / `exit` events |
| phone → | `input {terminalId, bytes(base64)}` | ptyd `write` with `id` (acknowledged) |
| → phone | `permission {requestId, taskId, tool, detail, truncated}` / `permission-done` | `agent-permission` events (`agents/permission.rs`) |
| phone → | `permission-answer {requestId, allow\|deny}` | same path as `POST /api/agent/permission` |

**Presence.** Only the app knows which ptyd terminal belongs to which session. `ptyd list`
ties a PTY to nothing but `cwd`/`pairKey`. So Swift pushes
`PUT /api/remote/presence` with `{taskId, title, project, cli, terminalId, agentState}` on
change, and the backend broadcasts it to connected phones.

**ptyd bridge.**
- **Connection:** the backend opens its own ptyd connection with
  `hello {dataEncoding:"base64", eventScope:"attached"}`.
- **Replay:** it forwards the 256 KiB replay ring (`RING_MAX`) on attach, then live
  events.
- **Allowed ops:** `list`, `attach`, `write`, `flow` only.
- **Never sent:** `create`, `kill`, `killAll`, `resize`, `appearance`, `snapshot*`.
- **Backpressure:** a slow phone never pauses the Mac's terminal. The bridge drops that
  phone at a per-connection cap instead of relaying ptyd `flow` pauses.

**Terminal size is the Mac's.** ptyd applies resizes last writer wins, and the Mac renderer
owns the size. The phone never sends `resize`: it renders at the Mac's cols×rows and fits
them to its width with pinch-zoom and horizontal pan. This needs one small ptyd change:
report the current `cols`/`rows` in `list`/`attach`, and emit an event when they change.

## iPhone app (`ios/CascadeRemote`, iOS 17+)

- **Screens:**
  - Hosts: usually one, auto-connects.
  - Sessions: list with agent state.
  - Session: terminal, key bar, composer.
- **Terminal:** SwiftTerm renders it. Our `ghostty-terminal-spm` has no iOS slice, and
  ptyd snapshots are Ghostty-revision blobs, so the phone uses ring replay only. If the
  ring is `truncated`, it clears first.
- **Input:**
  - A composer line sends on Return.
  - A key bar has Esc, Tab, ⌃C, ⌃D, arrows and Enter.
  - Hardware keyboard input goes straight through.
- **Info.plist:**
  - `NSLocalNetworkUsageDescription`.
  - The KVS entitlement.
  - No background modes. The connection drops in the background and reconnects on
    foreground, re-attaching from `seq`.
- **Sharing:** only the wire types. They are mirrored from the Rust definitions and held
  to them by shared JSON fixtures tested on both sides. No `APIClient` extraction is
  needed, because the phone never talks to the loopback API.

## Phases

Estimates are one person's working days, guessed from the size of comparable pieces in
this repo, not measured.

| Phase | Deliverable | Est. | Done when |
|---|---|---|---|
| **0. Apple gate** | Team, two App IDs, KVS entitlement on both, signed Mac build via the release pipeline | 1–2 + Apple lead time | A notarised Cascade and a dev-signed phone app round-trip one KVS key. Latency is measured and written down. **Go/no-go for everything below.** |
| **1. Listener + pairing** | `remote/` module, cert, challenge auth, allowlist, control routes; Swift KVS publisher, device approval, presence; phone Hosts + Sessions screens | 5 | Phone lists live sessions over Wi-Fi. Cargo tests prove unknown key rejected, unapproved key rejected, non-allowlisted path 404, auth rate limit |
| **2. Watch** | ptyd bridge (read ops), cols/rows in ptyd, SwiftTerm view | 4 | A running Claude Code session shows on the phone within 1 s of output, and reattach after background resumes without duplicate output |
| **3. Type** | `input` path, key bar, composer | 2 | A prompt typed on the phone reaches the agent. ⌃C interrupts it. The Mac view stays in sync |
| **4. Permissions** | Permission cards on phone; app stops auto-passing when a phone is attached to that session | 2 | Allow on the phone lets the tool run. Deny blocks it. The Mac card disappears (`agent-permission-done`) |

Phase 1's backend half (listener, auth, allowlist, tests) does not depend on Apple and
can start before Phase 0 finishes. Development builds are ad-hoc signed and cannot use
KVS, so they get a **debug-only manual host entry** (host, port, fingerprint) behind a
build flag.

## Risks

| Risk | Mitigation |
|---|---|
| KVS may not be granted to a Developer ID (non-App-Store) Mac app. **Unverified.** | Phase 0 proves it first. The fallback is the CloudKit private DB from 03-architecture.md, with the same records and the same flow |
| Phone input is remote shell control | Off by default, device approval on the Mac, per-device revoke, pinned TLS, allowlist of two paths, and a "Remote connected" indicator in the Mac toolbar while a phone is attached |
| The replay ring (256 KiB) cannot rebuild a full-screen TUI's current screen | Accept for v1 (clear and wait for the next redraw). Later: the bridge replays the ring into a headless `cascade-vt` terminal and sends a synthetic redraw |
| Stale addresses in KVS (DHCP, sleep) | `NWPathMonitor` republish, endpoint racing, a clear "not reachable: same Wi-Fi or Tailscale?" state |
| macOS firewall prompt on first listen | Expected once; document it in Settings → Remote |
| Phone and Mac typing at once interleave | Accept. Both write to the same PTY, as two local tabs would |
| `permission.rs` auto-passes when the chat is not on screen | Phase 4 changes the rule to "not on screen **and** no phone attached". The 280 s wait (`WAIT`) still bounds it |

## Open questions

1. Personal or organisation Apple Developer team? This decides the KVS identifier
   prefix, and it must match on both apps.
2. Keep the Mac-side Allow prompt for new phones? It is recommended, and costs one click
   per phone.
3. Is fixed port 27271 acceptable?
4. Should this land on a fresh branch from `main`? `remote` is 127 commits behind and
   still uses the Craft names. The recommendation is yes: carry only `docs/remote/`
   across.
