# Craft Remote — an iOS companion for the Mac app

Status: **research and plan, no code yet.** Branch `remote`.

Craft Remote is a phone app that watches and drives a running Craft on your Mac: the
dashboard (PRs, CI, Jira), the agent sessions, the iOS Simulator the Mac is streaming, and
later the terminals. Pairing goes through the user's own iCloud account, so there is no
QR code, token or port to set up.

| Document | What it holds |
|---|---|
| [01-requirements.md](01-requirements.md) | What was asked for, what is out of scope, and the decisions already taken |
| [02-research.md](02-research.md) | What the codebase and the platforms give us today, with `file:line` citations and verification status |
| [03-architecture.md](03-architecture.md) | The design: pairing, transport, the remote listener and its allowlist, the simulator and terminal relays, background alerts |
| [04-plan.md](04-plan.md) | Phases, work items, estimates, risks, open questions |

## The short version

- **Pairing = iCloud.** The Mac writes one `Host` record to the CloudKit private database:
  its reachable addresses, the fingerprint of a self-signed TLS certificate, and a bearer
  secret. A phone signed into the same Apple ID reads it and is paired. Revocation is
  rotating the record.
- **Transport = a new, separate listener in the Rust backend**, bound to non-loopback
  interfaces only when Remote is enabled, TLS with the pinned certificate, bearer auth on
  every request, and an explicit route allowlist. The existing loopback router and its
  `foreign_origin` trust are never exposed. Same Wi-Fi works out of the box; if both
  devices run Tailscale, the tailnet address is just another candidate and off-network
  works too, with no extra code.
- **Simulator = relay serve-sim's own page.** The helper already rewrites its stream and
  WebSocket URLs to whatever host the request came from, so the phone shows the same page
  the Mac shows, through the relay, in a `WKWebView`. No MJPEG parsing on the phone.
- **Terminal = a WebSocket bridge to ptyd.** ptyd already allows several attachers per
  terminal with ring-buffer replay and per-client backpressure. The bridge forwards
  newline-delimited JSON frames and filters ops to attach/write/resize/flow.
- **Alerts = CloudKit subscriptions.** The Mac writes an `Alert` record when an agent goes
  idle or a review is requested; CloudKit pushes it to the phone. No APNs server of our own.

## Prerequisite that blocks everything

CloudKit needs a provisioning profile with the iCloud entitlement, so it needs an Apple
Developer Program team. Craft is ad-hoc signed today with no `DEVELOPMENT_TEAM`
(`macos/Resources/Configs/Shared.xcconfig:26-27`). See [04-plan.md](04-plan.md) §Phase 0.
