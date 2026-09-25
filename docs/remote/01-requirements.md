# Requirements

Captured 2026-09-24 from the discussion that opened this branch.

## Goal

A mobile app that can remote-control the Craft desktop app running on the user's Mac.

## Must have

| # | Requirement | Notes |
|---|---|---|
| R1 | See the dashboard: projects, PRs with CI status, Jira tickets, agent sessions and their state | Read-only first |
| R2 | Act: approve/merge-adjacent actions, Jira transitions, start/stop a session, reply to an agent that is waiting for input | Second |
| R3 | **See the iOS Simulator output** the Mac is streaming, and ideally drive it (tap, swipe) | Explicitly requested |
| R4 | **Pairing through iCloud only.** No QR code, no token to type, no port to open. "Tint to the iCloud user": the Mac is discoverable by the same Apple ID and nobody else | Explicitly requested; iCloud is for pairing only, not for carrying live data |
| R5 | No complicated setup on either device | Follows from R4 |
| R6 | Alerts on the phone when an agent needs input or a review is requested | Discussed; the reason to have a phone app at all |

## Nice to have

| # | Requirement | Notes |
|---|---|---|
| N1 | Live terminal of a session on the phone, with input | Hardest piece; last |
| N2 | Works away from home Wi-Fi | Tailscale on both devices gets this for free (see research §E); a built-in relay is out of scope |
| N3 | Per-device revocation | v1 has one host secret; rotating it revokes every phone |

## Out of scope

- An Android app.
- A hosted relay/TURN service run by us. Off-network access is delegated to Tailscale.
- Syncing Craft's data through iCloud. CloudKit carries only the pairing record and small
  alert records; live state comes over the direct connection.
- Exposing the existing loopback API as-is. It has no authentication and trusts its callers
  (research §A).
- Editing files or running arbitrary git commands from the phone.

## Decisions already taken

| Decision | Why |
|---|---|
| Pairing via the CloudKit **private** database | Scoped to one Apple ID with no sharing step (research §E-a). Zero setup |
| Certificate pinning instead of TLS pre-shared keys | Apple's PSK support is TLS 1.2-only and rustls has no TLS 1.2 PSK ciphersuites (research §E-b). A self-signed certificate with its fingerprint published in the Host record works with rustls on the Mac and `URLSession`/`WKWebView` trust evaluation on the phone |
| The remote listener lives in the Rust backend, not in Swift | It needs HTTP, SSE, WebSocket proxying, a Unix-socket bridge and TLS. All of that is mature in tokio/axum/rustls and the router can be called in-process. CloudKit and the Settings UI stay in Swift, which is what Swift is good at here |
| Relay serve-sim's page rather than re-implement a viewer | serve-sim 0.3.1 rewrites its stream/WS URLs to the requesting host (research §C). `URLSession` cannot parse MJPEG natively (research §E-b), so a native viewer would cost more and give less |
| Phase the work read-only → actions → simulator → terminal | Each phase ships something usable; auth and the allowlist exist from phase 1 |

## Constraints inherited from the codebase

- `AGENTS.md`: views present what the API returns; route paths come from `Routes.swift`
  and `route_contract` must keep passing; no `gh` in request handlers; theme tokens only.
- The one bundled JavaScript page is the diff page; the relayed serve-sim page is *not*
  bundled, it is served by the helper, so this does not add a second bundled page.
- `craft.db` is durable and not regenerable: the host secret and certificate live there
  (or in the Keychain, see open questions) and must survive updates.
