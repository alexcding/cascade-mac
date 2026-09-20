# Terminal snapshots (integration builds)

Build the pinned runtime first, then enable the explicit integration feature:

```sh
python3 macos/scripts/build-ghostty-vt.py
cargo test --manifest-path crates/craft-ptyd/Cargo.toml --features terminal-snapshots
```

The native app and its bundle script require this feature; Tauri keeps its
existing feature-free helper protocol. Prepare both runtimes before building the
native app as described in `macos/README.md`. Craft snapshot v3 preserves glyph
registrations and Kitty images. The current handshake revision ends in
`-taskhub-appearance-v3`; the sections below describe each response contract.
Historical validation notes are records only: further UI/unit tests and benchmarks
are suspended at the user's request.

Native and headless runtimes share `0007-glyph-snapshot.patch`. The handshake
revision includes `-taskhub-glyph-v2`, distinguishing it from the original upstream
format before any shell is created or attached. Registration data is restored
through the glyph decoder directly; no old APC query or response is replayed into
the live shell. Existing version-1 daemons are preserved rather than replaced.

Each terminal owns a headless Ghostty parser from creation. Output enters that
parser and the legacy ring under one lock. Kernel and parser resizing run on the
terminal's I/O thread between output batches; an acknowledged resize completes
after the kernel size changes. Dimensions must be nonzero, at most 4096 on each
axis, and at most 1,048,576 total cells. Failed parser resizing invalidates further
snapshots of that terminal instead of returning stale state.

The existing `seq` counts only output batches, so legacy replay clients keep their
contiguous output sequence. `stateSeq` counts both output and successful parser
resizes. Data events include both. A resize event carries `ev:"resize"`, `id`,
`cols`, `rows`, `seq` and `stateSeq`. Snapshot clients must subscribe before capture,
buffer these events, import the captured state, then apply only events with newer
`stateSeq`, in order. A sequence gap requires a fresh capture. Existing clients
ignore the extra fields and resize events.

Protocol 2 gains optional operations, available only in feature builds:

1. `hello` returns `snapshotRevision`. To opt in, send `dataEncoding:"base64"`
   and the exact expected `snapshotRevision`. A mismatch is rejected. Repeating
   `hello` clears any transfer and requires negotiating again.
2. `snapshotBegin {term}` captures immutable binary state under the terminal lock.
   Its response contains `token`, `size`, `chunkBytes`, `seq`, `stateSeq`, `cols`,
   `rows` and `revision`. It releases the previous transfer before capturing.
3. `snapshotRead {token,offset}` returns `{token,offset,bytes,done}`. `bytes` is
   padded base64 for at most 128 KiB. Offsets must be chunk aligned and within the
   snapshot. Reads are repeatable, so transport retries do not mutate state.
4. `snapshotEnd {token}` frees that connection's capture. Stale tokens fail and
   cannot release a newer capture. Disconnect also releases it. Reads after
   60 seconds reject and release an expired capture; an idle connection can retain
   at most its single bounded capture until disconnect or its next snapshot operation.

Tokens have meaning only on the connection that created them. Capturing does not
pause or kill the shell. The 192 MiB snapshot cap is independent of the 8 MiB socket
outbox cap; whole snapshots are never queued to the outbox. The client may use the
existing connection-owned flow pause while downloading if its live-event buffer
would otherwise overflow. Connection loss releases that pause.

Validation uses the real static Ghostty library and an isolated PTY: output beyond
the 256 KiB tail, chunked snapshot transfer, alternate/primary screens, unfinished
SGR, saved cursor, a resize followed by future output, and restoration from a new
connection with the same shell PID. Tests also cover revision/token/offset errors,
expiry, byte/text coexistence and contiguous legacy output across resizes.

## State response ownership

Feature helpers advertise `stateResponseOwner:"daemon-state-v1"` in `hello`.
The native app requires it before creating a shell and sends the same value in
`create.opts.stateResponseOwner`. `create` and `list` return each shell's owner.
Ownership is fixed at creation; it never follows viewer count or connection state.
Unknown owners are rejected before spawning. The feature-free helper rejects any
explicit owner. Missing ownership retains the legacy silent parser, including in
feature-enabled builds, so existing Tauri shells keep their response path.

`daemon-state-v1` owns DSR operating status/cursor position, DECRQM except Kitty
paste mode 5522, DECRQSS, and Kitty keyboard-flag queries. It filters complete
synchronous Ghostty response packets, not raw requests, so fragmented queries and
snapshot continuations use the single authoritative parser. A shared maintained
parser patch enables ANSI DECRQM and rejects nonzero/multiple DA request parameters,
preventing echoed DA2 replies from triggering a feedback loop. Device attributes
and version/terminfo stay native for these older shells; new shells can use the
identity contract below. Geometry, graphics and appearance have the additional
contracts below. Clipboard and presentation effects retain the native live policy
described at the end of this document.

Replies are generated before snapshot capture can observe the advanced state and
queued by the same PTY I/O worker. They share the bounded input queue and preserve
accepted input order, but do not set `hasContext`. Collection is capped at 256 KiB
per output batch. Collection/queue/write failure latches input failure, discards the
unsent suffix and emits `inputError`; collection failure also invalidates snapshots.
Neither output nor uncertain input is retried and the shell is preserved.

After checking the shell owner, native attachment imports the snapshot and enables
selective suppression before applying any newer output. It suppresses only the
owned handlers, preserving native clipboard/UI effects and ordinary keyboard/paste
input. Ownership persists through terminal reset and new native surfaces on
reconnect. An older shell is preserved and rejected rather than silently switching
its response owner. Legacy renderers must not render state-owned shells; the native
app uses a separate daemon socket from Tauri.

Real-PTY validation queries with no clients, two snapshot observers and after their
disconnection, checking exact response bytes, same PID and unchanged `hasContext`.
Native tests verify suppression across split DCS and reset, native paste/capability
responses, and exactly one CPR with two live app surfaces.

## Native identity profile

`hello.identityResponseOwner` advertises `daemon-identity-v1`. New native shells
select that value in `create.opts.stateResponseOwner` and supply
`terminalProfile:{version,terminfoDirectory}`. The version comes from the actual
linked native renderer; the directory comes from its pinned package resources.
This contract includes all `daemon-state-v1` replies plus primary/secondary device
attributes, XTVERSION and XTGETTCAP. Tertiary DA stays silent, as in native Ghostty.
DA advertises the native default clipboard-write policy; a native surface with a
different policy rejects identity ownership. Clipboard contents remain UI-owned.

Before spawning, the daemon validates the profile and copies the compiled
`xterm-ghostty` entry into `<data>/terminfo/<terminal-id>/78/xterm-ghostty`. The shell
receives `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION` and
`TERMINFO` pointing to its private copy. The returned/listed profile contains that
copy's path. An app move, bundle replacement or reconnect cannot change an existing
shell's reported version or break its terminfo path. Normal exit/reaping removes
the copy; failed creation also cleans it up. Copies left by a daemon crash may
remain for later cleanup; unrelated data and other live helpers are never swept.

Old state-owned shells remain attachable with their original response path. A new
shell requires the new helper capability; missing/invalid profiles or unsupported
owners reject before spawning. Import selects state-only or state-plus-identity
suppression according to the shell, before live output. Ordinary paste and native
clipboard-mode handling remain active.

Verification uses the real bundled terminfo with macOS `tput`, deletes a temporary
source bundle after creation, checks exact identity replies with no native view
and with two live native surfaces, and verifies same-PID snapshot reattachment and
copy removal after reaping. Runtime/native regressions cover ANSI mode queries,
echoed DA replies, split XTGETTCAP, terminal reset and invalid clipboard policy.

## Pixel geometry ownership

Feature helpers advertise `hello.geometryResponseOwner:"daemon-geometry-v1"`.
Creation can opt in with `opts.geometryResponseOwner` set to that exact string,
alongside `stateResponseOwner:"daemon-identity-v1"`, its identity profile, and
`geometry:{cols,rows,cellWidthPixels,cellHeightPixels}`. This adds CSI 14/16/18 t
and mode 2048 replies to the identity/state set. Missing geometry, unsupported
ownership or geometry without ownership fails before shell creation. New native
app sessions supply measured cells before creation and suppress matching replies
after import. The app rejects a helper that claims the capability but omits the
requested owner in its creation response. Existing sessions retain their original
state/identity-only ownership, without a mid-session switch.

The parser and kernel PTY receive the initial geometry before the child starts,
so the first query and TIOCGWINSZ agree. Cell pixels must be nonzero. Each grid
axis/product must satisfy the existing parser bounds, and each pixel dimension
must fit the kernel's unsigned 16-bit winsize fields. Overflow is rejected;
metrics are never truncated or rounded to fit.

Owned sessions require the same complete `geometry` object on every resize,
with the existing top-level `cols`/`rows` matching its values. Legacy/state-only/
identity-only sessions reject added geometry, preserving ownership from birth.
The I/O worker applies kernel and parser geometry between output batches. A
pixel-only change advances `stateSeq` and emits a resize event; equal geometry
does neither. Geometry-bearing events and snapshot headers include the complete
`geometry` object. Older sessions omit that field.

Queries read the authoritative parser's current metrics. Enabling mode 2048
produces its initial report; subsequent grid or cell-pixel changes produce one
report through Ghostty's resize effect. These bytes use the existing bounded
protocol input queue without setting `hasContext`. Disable stops notifications.
Observers and reconnects do not generate reports or change ownership. Native
surfaces must suppress matching size-query/mode-enable/resize replies after
import while retaining title reports and unrelated native effects.

A real raw PTY program verifies initial and changed TIOCGWINSZ pixels, exact
reply bytes with no clients and two snapshot observers, pixel-only and grid
resizes, unchanged-size deduplication, mode disable, snapshot metrics, same PID
and unchanged `hasContext`. Invalid/partial/mismatched sizes do not advance state.
The native app fixture also verifies exactly one size-query/enable/resize response
with two live surfaces, geometry-bearing snapshot reattachment, and new-session
creation through the native Zsh integration path. Native bridge tests cover actual
backing-scale rounding, pixel-only changes, split queries/reset and unchanged
title/input policy. App resizes enqueue acknowledgements in callback order, with
a synchronization fence before capture; rejected sizes stop the pipeline visibly.
Transient delivery loss follows existing reconnect/input-safety checks.

## Shell integration resources

`hello.shellIntegration:true` advertises support for the optional
`terminalProfile.resourcesDirectory`. New native sessions require that capability
before creating a shell, avoiding silent field loss with older helpers. Existing
profiles without resources remain attachable with their original behavior.

The daemon copies the pinned package's Zsh/Bash scripts and license from a fixed
five-file allowlist, including Zsh's hidden `.zshenv`, into the shell's private
resource directory. Reads are capped at 1 MiB total; missing/empty/oversized files
fail creation and the profile guard removes partial copies. Returned profiles
record the private resource path, which lives until shell reaping.

Absolute Zsh executables use the package's ZDOTDIR bootstrap, preserving the
original ZDOTDIR and allowing the user's `.zshenv` to relocate it. Normal login,
rc and prompt hooks run, then the bundled integration reports OSC 7 working
directory and OSC 133 prompt/command boundaries. Title/cursor features are enabled.
Supported non-Apple Bash uses the pinned `--posix`/ENV mechanism and restores the
user's ENV and history settings. Apple's `/bin/bash` (including symlinks), relative
executables and other shells retain their existing startup arguments; scripts
remain available for manual integration. No startup file is edited and no command
is injected into a running shell to enable integration.

A real `/bin/zsh` test isolates its home and startup files, relocates ZDOTDIR,
checks startup order and user prompt/hooks, changes into a Unicode/spaced path,
verifies native working-directory/file-link state and command exit markers, then
reattaches a fresh native surface to the same PID. Resource bounds/lifetime and
Bash environment preservation have automated coverage. Executing Homebrew Bash
still needs acceptance on a machine with that shell installed.

## Graphics snapshot v3

The graphics format introduced `-taskhub-graphics-v3` (superseded by the current
appearance handshake revision). It retains v2 glyph
registrations and adds one CRC-framed graphics record per screen after history.
The native client completes the entire import before delivering post-cut output;
v3 is not an interleaved live-history import format.

Records own decoded image pixels (or pending payload lengths), pinned/virtual/
relative placements, animation frames and playback state, generated ID counters,
and unfinished chunked image/frame transmission metadata and bytes. Placement
pins use distance from the bottom of the complete screen; expired history pins
and orphaned relative descendants are dropped. Image generations are rebased in
age order, preserving eviction order without colliding with native texture caches.
A frame transmission keeps its target-generation relationship. Playback resumes
the captured frame on a fresh renderer clock.

Both builds enable Wuffs PNG decoding and use a 32 MiB image budget per screen,
including animation frames, plus a 32 MiB unfinished-transfer limit. Image loading
uses direct payloads in daemon-owned sessions. Import does not reopen image files,
access shared memory, send replies, move the cursor, or replay host effects. Each
graphics record is bounded at 80 MiB; the full snapshot is bounded at 192 MiB.
Malformed, duplicate, oversized or incompatible records reject restoration rather
than partially installing images. Native and Rust build scripts require the same
maintained graphics patch. Existing incompatible helpers/shells remain preserved.

This implementation was compiled for the headless runtime, native renderer and
helper. No new UI or unit tests were added or run, per the user's direction.

## Detached graphics replies

New native sessions negotiate `daemon-geometry-graphics-v2` through the existing
geometry ownership field. This includes the v1 pixel/state/identity replies plus
Kitty graphics and glyph-protocol acknowledgements and queries. Replies come from
the daemon's authoritative parser, including when no client is connected. Native
surfaces still apply image and glyph changes but suppress these acknowledgements,
so attaching more than one surface cannot double them. Clipboard and UI effects
remain outside this response set. Old owners are rejected before new shell creation;
existing incompatible shells are preserved rather than restarted automatically.

The headless library still produces the complete synchronous response; the Rust
collector accepts only the added complete APC response packets within its existing
256 KiB batch limit. Fragmented commands use the same parser and snapshot continuation
as all other output. This phase adds no UI or unit tests.

## Appearance ownership

New sessions also negotiate `appearanceResponseOwner:"daemon-appearance-v1"`.
This requires geometry/identity ownership and a native appearance at creation.
The `appearance.values` array contains 256 palette RGB values, foreground,
background, cursor (or UInt32.max for the foreground fallback), and a light/dark
scheme value (0/1). RGB values are bounded to 24 bits. The native bridge uses the
product's 16-bit OSC color-report format.

An `appearance` request updates defaults through the same ordered PTY worker as
resize. Changed defaults advance `stateSeq` and publish an `appearance` event;
unchanged defaults do neither. Snapshot headers retain those defaults. Native
surfaces apply the captured defaults before newer events, preserving explicit OSC
overrides. Config callbacks copy and enqueue values without re-entering Ghostty.

The daemon answers OSC palette/dynamic-color and Kitty color queries, color-scheme
queries, and mode 2031 notifications. It retains the last native configuration
while detached. Native handlers still apply color mutations but suppress the owned
replies. The revised handshake prevents older renderers from ignoring this owner.

## Native live UI policy

Clipboard reads/writes (OSC 52 and Kitty clipboard, including mode 5522), title
reports, visibility/focus and other presentation effects remain native operations.
They use the attached surface's actual state and existing Ghostty permission policy.
The headless daemon does not access the macOS clipboard, synthesize consent,
pretend that a window is visible, or queue UI requests for later execution. With no
native surface, these UI-dependent queries have no reply; applications must use
their normal unsupported-terminal timeout/fallback. Clipboard access while detached
is deliberately unsupported.

Completed historical effects are not replayed at attachment: snapshots restore
state directly, and only output after the capture boundary reaches the native live
handler. Titles and working directories are restored as metadata. Incomplete escape
sequences retain parser continuation and may finish in future live output. Hiding a
pane retains its native emulator, so hiding and detaching have different lifecycles.
This policy does not claim daemon ownership or multi-view deduplication of native
UI effects; the app retains one emulator per terminal session.
