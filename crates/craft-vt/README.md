# Headless terminal snapshot runtime

This crate owns a headless Ghostty terminal and exposes binary snapshot capture and
restore for the detached PTY daemon. The daemon consumes it in builds with the
`terminal-snapshots` feature, required by the native macOS app. Tauri retains its
feature-free helper protocol.

Build the pinned runtime and run its real-library tests:

```sh
python3 macos/scripts/build-ghostty-vt.py
cargo test --manifest-path crates/craft-vt/Cargo.toml
```

The script downloads a checksum-verified Zig toolchain into `macos/.build/ghostty-vt`,
checks out the same Ghostty revision as the native renderer, and builds a static
library. It does not install global tools. `CRAFT_GHOSTTY_VT_DIR` may select an
already-built runtime; its revision marker must match. The Rust build copies the
archive under a unique name so Apple ld cannot substitute the upstream dylib.

Every terminal operation requires exclusive mutable access. Snapshots retain primary
and alternate screens, saved cursor, modes, styles, hyperlinks and scrollback, plus
up to 1 MiB of unfinished parser input. Scrollback is limited to 8 MiB, subject to
Ghostty's page-sized allocation granularity. Encoded snapshots are capped at 192 MiB;
truncated, corrupted and trailing data is rejected. Diagnostic VT formatting is not
used to restore state.

Snapshots are not a stable cross-version disk format. Encoder and decoder revisions
must match. Craft's version 2 adds a checksummed glyph registration record,
retaining registration order, metrics, width, alignment, padding and outline data.
Decoding uses the same glyph validation and namespace rules as a live registration,
without replaying terminal output or emitting responses. The negotiated revision is
`82938b633ba646db38591d969c3c526332bd7e65-taskhub-glyph-v2`. Version 1 helpers are
rejected before attachment and their shells remain running. Kitty image payloads
and placements are still outside this extension.
See the [pinned snapshot format source](https://github.com/ghostty-org/ghostty/blob/82938b633ba646db38591d969c3c526332bd7e65/src/terminal/snapshot/terminal.zig).

The daemon now parses every output batch, serializes kernel/parser resizes on its
I/O thread, and captures an atomic sequence boundary. Its connection-owned transfer
returns at most 128 KiB per read, with one snapshot of at most 192 MiB per connection.
See [the daemon snapshot protocol](../craft-ptyd/SNAPSHOTS.md).

The native app imports state into a fresh surface before applying newer output
and ordered resizes, preserving the shell across reattachment and reconnect.

`feed_with_responses` additionally collects the pinned runtime's synchronous
protocol replies, capped at 256 KiB per call. It applies input exactly once and
clears its temporary C callback/userdata before returning. If collection fails,
state may already have advanced: discard the partial reply buffer and do not
retry the input. Plain `feed` continues to parse silently. This API does not access
the host clipboard or write to a PTY; default runtime replies can include protocol
denials for unsupported host effects.

`feed_state_responses` filters complete response effect packets to the fixed
`daemon-state-v1` set: DSR status/cursor, DECRQM except native clipboard mode 5522,
DECRQSS, and Kitty keyboard flags. The daemon selects this only for shells created
with that owner; legacy shells retain silent `feed`. The native renderer suppresses
the identical set after import. Clipboard/UI, geometry, colors, device identity
and other configuration-dependent reports remain renderer-owned and require more
work for complete offline behavior. See the daemon protocol for the contract and
failure handling.

`feed_identity_responses` extends state ownership with native DA1/DA2, XTVERSION
and XTGETTCAP. The shell's creation profile supplies the printable product/version;
TN reports `xterm-ghostty`, matching its environment and bundled terminfo. Temporary
identity callbacks and terminfo configuration are cleared after each feed.

`resize_geometry` accepts nonzero cell dimensions in pixels, checks pixel-product
overflow, and collects Ghostty's own mode 2048 resize notification. Equal geometry
is a no-op; changes to cell pixels alone still update the parser and report once.
`geometry` reads these exact metrics from parser state, including restored
snapshots. `feed_geometry_responses` adds CSI 14/16/18 t and mode 2048 replies to
the identity/state set, with the same bounded collector and callback cleanup.
It requires initialized pixel geometry; title, clipboard, colors and other host
effects remain excluded. The daemon exposes these APIs through the optional
`daemon-geometry-v1` creation contract, including initial kernel winsize, ordered
resize and snapshot metadata. New native app sessions negotiate that ownership
and suppress the matching reports after import. Existing sessions retain their
original ownership. See the daemon protocol for the narrower kernel pixel bounds
and required creation/resize fields.

Both native and headless builds apply
`macos/patches/ghostty/0003-terminal-query-validation.patch`. It rejects echoed DA2
responses as requests and enables the existing ANSI DECRQM handler. The runtime
builder applies/reverses that exact patch around a clean pinned source build and
records the patch bytes beside the revision. The Rust build rejects a missing or
mismatched marker, preventing accidental use of an older unpatched archive. These
query changes do not alter the upstream revision. Both builds additionally apply
`0007-glyph-snapshot.patch`, and the Rust build requires its exact marker. Glyph
records allow up to 1,024 entries, cap each raw registration at the existing 1 MiB
parser limit, and cap the record at 16 MiB within the complete snapshot's 192 MiB
limit. Oversized captures fail explicitly instead of omitting glyphs.
