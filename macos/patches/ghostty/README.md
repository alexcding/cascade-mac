# Native Ghostty snapshot bridge

These patches extend the exact Ghostty and Swift wrapper revisions in
`macos/scripts/ghostty-vt.lock.json`. Apply the wrapper's own patch stack first,
then `0001-native-snapshot-import.patch`, `0003-terminal-query-validation.patch`
and `0005-native-render-diagnostics.patch` to Ghostty; apply
`0002-swift-snapshot-import.patch`, `0004-appkit-appearance-publication.patch` and
`0006-swift-render-diagnostics.patch` to the wrapper. The maintained build script
does this in generated checkouts; do not edit SwiftPM dependency checkouts.

`ghostty_surface_restore_snapshot` / `InMemoryTerminalSession.restoreSnapshot`
imports a complete bounded snapshot into a fresh host-managed surface. Call on
the main actor before exposing the surface to input or feeding live output.
The capture supplies the logical grid independently of the current physical view.
Invalid, truncated or trailing
data returns false without changing the original terminal. Search, selection,
composition, previous output and a second import also reject the operation.

The importer holds the terminal/renderer mutex while replacing state, places the
terminal at its final address, and reconstructs continuation with the supported
read-only standard TerminalStream. It verifies byte-identical continuation export,
then moves the shared Parser, UTF8Decoder, APC and DCS builders to the native
StreamHandler. It does not replay those bytes through a second handler. Future
output, key encoding, paste framing and terminal replies use normal native paths.
Host visual defaults remain configured while explicit terminal color overrides
and snapshot contents survive.

Before feeding live output, call `publishSnapshotMetadata()` on a worker and
keep draining `flushSnapshotMetadataCallbacks()` on the main actor. Publication
uses the native title and OSC 7 handlers, including local-host validation and
percent decoding. It converts the headless parser's working-directory URI into
the native path without feeding bytes into an unfinished parser. Publication is
allowed once, before subsequent output; callback draining holds no native surface
operation, allowing a callback to close the surface safely. Craft's attachment
pipeline owns this worker/tick lifecycle, including hidden surfaces.

After import, physical view resizes request a host resize without reflowing the
logical terminal. Apply each daemon resize event with
`InMemoryTerminalSession.applyHostGridSize(columns:rows:)` in the same serial
queue as output. The wrapper drains preceding bytes before changing the grid;
later output then uses that grid. Input stays gated until attachment completes.

This is a Craft extension, not an upstream snapshot compatibility promise. The
native app consumes the generated local Swift package for download/import and
ordered live resizes. Transient transport loss reconnects through a fresh surface
only when input delivery was settled; uncertain input requires manual recovery.
Offline query response ownership, native default/config synchronization and
UI-dependent effects remain follow-up work. Craft v3 preserves glyph registrations
and Kitty graphics through `0007-glyph-snapshot.patch` and
`0008-graphics-snapshot.patch`, applied to both builds. See
`crates/craft-ptyd/SNAPSHOTS.md` for ownership, resource limits and restoration.

Historical integration commands (UI/unit runs are currently deferred by user direction):

```sh
python3 macos/scripts/build-ghostty-vt.py
python3 macos/scripts/build-ghostty-native.py
cargo build --manifest-path crates/craft-vt/Cargo.toml --example snapshot
xcodebuildmcp swift-package test --package-path "$PWD/macos/GhosttySnapshotTests"
```

The native build requires Apple's Metal compiler component. It uses a local,
single-slice arm64 XCFramework and the wrapper's local package manifest. A build
input fingerprint and source-diff hashes reject unexpected generated-source edits.
Changed patches are reapplied after reversing the previously recorded generated
changes, including newly added files. Older build directories without complete
patch tracking require a fresh `--build-root`. `--zig` selects the pinned
toolchain explicitly, and `--global-cache` permits reuse of its dependency cache.
With another build root, set `CRAFT_GHOSTTY_PACKAGE` to its `package` directory
when running the integration suite. The Rust example accepts VT bytes on stdin
and produces a snapshot; it never executes commands or accesses application data.

The tests exercise a real native surface with history beyond the daemon replay
tail, primary and alternate screens, saved cursor, restored paste/key modes,
unfinished SGR, split UTF-8, OSC, DCS and APC, and live cursor-query responses.
They verify that rejected imports preserve the surface and historical queries
do not send replies to the shell. Metadata checks cover local/remote URIs, title
fallback, preserved parser continuation and surface closure during callbacks.
These tests establish the bridge behavior;
they do not establish complete app reconnection or the M1 performance gate.

## Appearance publication during native attachment

`0004-appkit-appearance-publication.patch` fixes two measured synchronous
publication paths: AppKit's `viewDidChangeEffectiveAppearance` during attachment,
and the SwiftUI wrapper's appearance callback inside `Update.dispatchActions`.
AppKit coalesces updates onto the next main-queue turn and reads the current
appearance only if the view is still attached and still presents its state.
SwiftUI forwards a deferred request to the wrapper model; stale requests and
replaced/detached view or controller identities are rejected. The public imperative
`adopt` API stays synchronous.

The patch changes only Swift appearance handling. It does not defer terminal input,
output, resize or focus callbacks, replace the emulator, or alter the native archive.
`TerminalAppearanceTests` verifies no synchronous publication during direct AppKit
and SwiftUI mounts, final appearance after rapid changes, detached-view cancellation
and surface identity across reattachment. It observes the pinned wrapper's Combine
publisher only in tests; Craft application models continue to use `@Observable`.

## Native render diagnostics

The `0005`/`0006` patches expose `TerminalSurface.submittedFrameCount`, an atomic,
read-only count tied to `renderer/generic.zig`'s actual frame completion/submission
call. On the pinned Metal backend that call commits an encoded command buffer.
Both the native renderer thread and the embedded host draw entry reach this path;
wrapper display-link ticks or refresh requests alone do not increment it. Reading
the count does not acquire the render mutex, tick, refresh or draw. A released Swift
surface returns `nil`; every replacement surface starts its own count at zero.

The counter measures submitted frames, not individual GPU draw calls, GPU duration,
GPU completion or physical display presentation. It adds one relaxed atomic increment
per submitted frame and makes no scheduling or visibility changes. Metal's unchanged
`presentLastTarget` path is a no-op, so it does not submit uncounted redraws.

`ghosttyParsesHiddenOutputAndEncodesKeysAndPaste` first checks that showing the real
surface advances the count, then verifies stable counts while the same hidden surface
parses Unicode/alternate-screen output and handles native keyboard, paste and links.
`TerminalStressHarness` allows two seconds for mount/occlusion work to settle, records
all ten initial counters and includes them in every resource sample. Any hidden
counter advancing fails the workload; the visible counter must advance, hidden
output must progress, and existing PID/surface identity checks remain in force.

## Graphics response ownership

`0009-native-graphics-replies.patch` suppresses Kitty graphics and glyph replies
only for surfaces paired with `daemon-geometry-graphics-v2`. Native state mutation
and rendering stay active. The new ownership string is required at creation and
attachment; older state/identity-only sessions keep their prior response path.
