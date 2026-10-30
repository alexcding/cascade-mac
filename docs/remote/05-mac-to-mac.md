# Mac to Mac: see another Mac's sessions

Status: **phases 1–3 (listener, pairing, this Mac's links) built**; the app (phase 4) is next, `crates/cascade-backend/src/remote/`. Decided 2026-10-29. This comes before the phone app in
[03-architecture.md](03-architecture.md) and replaces its iCloud pairing for now. The remote
listener, its allowlist and the terminal bridge are shared with that design.

## What it is

A Mac running Cascade (the *host*, e.g. a Mac mini) lets another Mac running Cascade (the
*client*) see its agent sessions. The client's sidebar gets one section per paired Mac, under
Pinned and Projects:

```
Pinned
  remote-pairing
Projects
  ▸ cascade-mac
mac-mini                      ●
  release-0.3.2      cascade-mac
  flaky-ui-tests     cascade-mac
```

Clicking a remote session opens its chat. Everything runs on the host: its `claude` and
`codex` sign-ins and limits, its disk, its `gh`/`git`/SSH credentials. The client sends only
what the person types and approves, and no credential crosses between the Macs.

## Decisions

| Decision | Why |
|---|---|
| **Pair once on the local network, with a 6-digit code.** No iCloud, no Developer team | Works between Macs on different Apple IDs and in ad-hoc ⌘R builds. iCloud and pairing links are later ways into the same sessions |
| **The network never grants trust.** TLS with a pinned certificate and a token on every request, on the LAN too | Off-network access (Tailscale, SSH) is then only another address, with no change to the security model |
| **The code is checked with SPAKE2** (RustCrypto `spake2`) | Someone watching the network learns nothing and cannot guess the code offline; one online guess per attempt, and the host ends pairing after 3 wrong ones |
| **One session per paired client, revocable on its own** | Fixes N3 of [01-requirements.md](01-requirements.md). The host keeps a hash of each token, never the token |
| **A separate listener with an allowlist**, as in 03 §2 | The loopback router has no auth and trusts its callers; exposing it is a shell on the Mac |
| **The client's own backend is the client.** It pairs, holds the token and pinned certificate, and proxies to the host; the app reaches a remote Mac through its own loopback `APIClient` | SPAKE2 and pinned rustls already live in Rust; `APIClient` stays loopback-only (`APIClient.swift:86-91`); "the app reaches the backend only through `APIClient`" stays true; one place holds secrets |
| **Remote sessions get their own sidebar section and model**, not merged into Pinned or Projects | The local models stay unaware of other Macs. A remote section is added beside them |
| **Read-only first** | Auth and the allowlist ship before anything that changes the host |

## Pieces

```
 Client Mac (Cascade)                                Host Mac (Cascade)
 ┌────────────────────────────────┐                ┌──────────────────────────────────┐
 │ Sidebar: RemoteHostSection     │                │                                  │
 │   └ RemoteSessionsModel        │                │                                  │
 │ APIClient (loopback) ──────┐   │                │                                  │
 │ Rust backend               ▼   │                │ Rust backend                     │
 │   remote::peers ───── TLS + token ─────────────►│   remote::listener (TLS, port P) │
 │     proxy, event relay     │   │  LAN / tailnet │     auth ► allowlist ► handlers  │
 │     pairing (SPAKE2) ──────┘   │                │     /pair (SPAKE2, while open)   │
 │ NWBrowser _cascade._tcp ◄──────┼── Bonjour ─────┤ DNSServiceRegister (Swift)       │
 └────────────────────────────────┘                └──────────────────────────────────┘
```

### Host: the listener (`crates/cascade-backend/src/remote/`)

- Off until Settings → Remote → "Allow other Macs" is on. Then a second axum server on
  `[::]:P` with rustls: `P` is picked on first enable and stored, so a client's saved address
  stays valid across restarts.
- Certificate: `rcgen` self-signed, CN `cascade-<instanceId>`, key and certificate in
  `cascade.db` settings (same trust level as `jira_api_token`; Keychain later).
- At most 32 connections at once, and each must finish its handshake and each request's
  headers within 10 seconds, so a peer without a token cannot hold the app's descriptors.
- Every route but `/pair/*` requires `Authorization: Bearer <token>`. The middleware hashes
  the token (SHA-256) and looks it up in `remote_clients`; unknown or revoked is `401`.
- The allowlist is its own `Router` naming each path and the same handler `build_app` uses.
  It never falls through to the loopback router. A `remote_contract` test lists it.

Read-only allowlist (phase 1):

| Route | Note |
|---|---|
| `GET /api/backend/health` | `instanceId`, name, version, capabilities |
| `GET /api/tasks` | the sessions |
| `GET /api/projects` | for each row's project label only |
| `GET /api/stream` | filtered to `Tasks`, `ChatThread`, `ChatShell`, `ChatRemoved`, and `Reload` (sent when the client fell behind, so it reads again) |
| `POST /api/chat/rpc` | filtered by method: `orchestration.getShellSnapshot`, `orchestration.getThreadDetailSnapshot`, `orchestration.getTurnDiff`, `orchestration.getFullThreadDiff`, `chat.listThreads`, `chat.providerStatuses`. Every other method is `403`, so no `dispatchCommand`, `projects.readFile` or `attachments.*` |

`remote_clients` (in `schema_durable.sql`): `id`, `label` (the client Mac's name),
`token_sha256`, `created_at`, `last_seen_at`. Revoking deletes the row and ends that client's
open stream. `remote_host` holds the one certificate and key (DER), whether the listener is on,
and its port.

### Pairing

1. On the host, Settings → Remote → "Pair a Mac…" opens a sheet showing a 6-digit code. While
   it is open, and only then, the app advertises `_cascade._tcp` with Bonjour
   (`DNSServiceRegister` for port `P`; TXT: `id=<certificate SHA-256>`, `name=<Mac name>`) and
   `/pair` answers. Closing the sheet, a successful pairing, 5 minutes or 3 wrong codes end it.
2. On the client, Settings → Remote → "Add a Mac…" lists what `NWBrowser` finds. Picking one
   and typing the code sends `POST /api/remote/peers/pair {address, code}` to the client's own
   backend.
3. The client backend opens TLS to the host, accepting any certificate whose key the server
   holds *for this first request only*, and records its fingerprint. It sends its SPAKE2
   message (`POST /pair/start {message, label}`); the host answers with its own and a session
   id. Each `/pair/start` is one of the window's 3 attempts.
4. Each side proves it has the SPAKE2 key with an HMAC over both messages and **the certificate
   fingerprint as it sees it**: the client first (`POST /pair/finish {session, proof}`, on a
   connection pinned to the fingerprint it recorded), then the host in its answer. A machine in
   the middle shows the client a different certificate, so the client's proof does not match
   what the host computes and the host refuses it (`403`).
5. Only after the client's proof checks does the host create a `remote_clients` row and answer
   with the token, its name and its own proof, over that pinned connection. The client checks
   the host's proof, stores a `remote_peers` row (`id` = the host's certificate SHA-256, which
   lasts across its restarts, unlike the backend's per-launch `instanceId`; `name`,
   `addresses`, `token`), and pins that certificate from then on.

The host keeps the client and sends the token before the client has checked the host's proof,
so an answer lost on the way leaves the host listing a Mac with no token until it is revoked.
Accepted for v1.

`/pair/start` and `/pair/finish` are the only listener routes without a token, and answer only
while the window is open. A right proof closes the window; so do closing the sheet, 5 minutes,
and the third failed attempt. Three `/pair/start`s use the window up even if none finishes:
the host hears `remote-pairing` whenever the window opens, closes, pairs a Mac or is used up,
and reads `GET /api/remote/pairing` (`{open, attemptsLeft, seconds}`) to show it.

### Client: peers and the proxy

- `remote::links` runs one task per paired host: it keeps the host's `/api/stream` open,
  trying its stored addresses in turn, and drops a stream silent for 45 seconds (the host sends a
  keep-alive every 15). It tries once at start and after pairing; a stream that ends is opened
  again once at once, which hears why. Nothing tries an unreachable host on a timer: only
  Settings → Remote, while it is open, through `POST /api/remote/peers/{id}/connect`
  `{address?}` (on opening, and when Bonjour sees the host, at the address it resolves). A `401` means this Mac was revoked there, and another certificate at
  the address means the Mac there is not the one paired (its data was reset, or another took
  the address): either way the link stops. A revoked host takes pairing again; a changed one
  is tried again at an address Bonjour resolves for its `id` (DHCP and sleep change addresses),
  which goes first among its addresses (at most four).
- Loopback routes for the app (to be added to `Routes.swift` in phase 4):
  - `GET /api/remote/peers`: each paired host's `id`, `name`, `addresses` and `reach`
    (`connecting`, `online`, `offline`, `revoked`, `changed`).
  - `POST /api/remote/peers/{id}/connect` `{address?}` → `{reach}`: try it again, for
    Settings → Remote; one online, being reached or revoked is left as it is.
  - `DELETE /api/remote/peers/{id}`: forget it, and stop its link.
  - `GET /api/remote/peers/{id}/tasks`, `GET /api/remote/peers/{id}/projects`,
    `POST /api/remote/peers/{id}/chat/rpc`: forwarded to the host as they are, one pinned
    connection per request; the host's answer comes back with its status, `404` for a Mac not
    paired, and `502` when no address answers. A large answer may take as long as it keeps
    coming (15 seconds at most between pieces, 64 MiB at most). The host's own lists decide what passes.
- Events: what the host's stream carries comes back as `Event::Remote { peer, event }`
  (`{"type":"remote","peer":…,"event":{…}}`), and a change in whether it answers as
  `Event::RemotePeer { peer, reach }`.

Host-side loopback routes: `GET /api/remote` (on or off, port, fingerprint),
`POST /api/remote/enable` and `/disable`, `GET /api/remote/clients`, `DELETE /api/remote/clients/{id}`
(revoke), `POST /api/remote/pairing` (open the window; returns the code) and `DELETE` (close it).
Client-side, from phase 2: `GET /api/remote/peers`, `POST /api/remote/peers/pair
{address, code, label?}`, `DELETE /api/remote/peers/{id}`. Events: `remote-clients` when a Mac
pairs or is revoked, `remote-peers` when this Mac pairs with or forgets one.

### App

- `Services/Remote/`: `RemoteAdvertiser` (Bonjour while the pairing sheet is open),
  `RemoteBrowser` (`NWBrowser`), `RemotePeersStore` (peers and their sessions, from the
  proxied routes and the `remote` events).
- Sidebar: one section per peer after Projects, with a reachability dot; each row shows the
  session title and its project's name. Not pinnable in phase 1.
- Opening a remote session shows its chat read-only. It reuses the chat page with a
  `ChatPageBackend` that answers from `POST /api/remote/peers/{id}/chat/rpc`.
- Settings → Remote: allow other Macs, pair a Mac, the paired clients with Revoke (host),
  the paired Macs with Forget (client).
- `App-Info.plist`: `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_cascade._tcp]`.
  macOS asks for local network access once, on both Macs.

## Plan

Each phase ends with its tests green and an independent review before the next.

| Phase | Work | Exit |
|---|---|---|
| 1 Listener | `remote/` module: certificate, `remote_clients`, rustls listener, token middleware, allowlist, the chat RPC and stream filters; host loopback routes. Tests: no token → 401, revoked token → 401, an existing loopback route → 404 on the listener, a filtered RPC method → 403, an allowlisted route answers over TLS | `cargo test` proves a request needs a valid token and reaches only the allowlist |
| 2 Pairing | `/pair` with SPAKE2 and the fingerprint MACs; pairing window and attempt limit; client `remote_peers` and `POST /api/remote/peers/pair`. Tests: two backends in one process pair; a wrong code fails, and the third ends the window; a different certificate in the middle fails | Two backends pair in a test with no app |
| 3 Client proxy | `remote::peers` connections, the proxied routes, `Remote` and `RemotePeer` events, reconnect | The client backend lists the host's sessions and relays its events, in a test |
| 4 App | Bonjour advertise and browse, Settings → Remote, the sidebar section, the read-only chat | On two Macs on one Wi-Fi: pair with the code, see the Mini's sessions, open one's chat |
| Later | Act on remote sessions (reply, approve, stop), the terminal bridge (03 §6), Tailscale addresses, pairing links, iCloud pairing, Keychain for tokens | |

## Open questions

1. Does anything on the host need to show that a client is watching (a dot in the toolbar)?
2. Should "Allow other Macs" stay on across restarts? The plan assumes yes once enabled; only
   *pairing* is limited to the sheet being open.
3. Decided: a stream that is up stays open; an unreachable Mac is tried again only from
   Settings → Remote (on opening it, and when Bonjour sees the Mac), never on a timer.
4. Follow-up outside this work: the loopback router checks no `Host` header, so a page that
   rebinds its DNS name to 127.0.0.1 can read GET routes. It already could read `/api/tasks`;
   the remote proxy adds the paired Macs' sessions. A loopback-wide `Host` allowlist fixes both.
