#!/usr/bin/env bash
# Prepares everything the Craft Xcode scheme needs, so Run in Xcode is the only
# step: a Rust toolchain, the prebuilt Ghostty VT runtime, and the Rust backend +
# PTY helper the scheme launches. Idempotent: re-running after a successful
# bootstrap only performs a fast cargo no-op build.
#
# Xcode runs this twice per build. The scheme's Build pre-action does the
# first-time work, and a Run Script phase re-runs it so any failure lands in the
# build log with the real error.
#
# The GhosttyTerminal Swift package itself needs nothing here: the project pulls
# github.com/alexcding/ghostty-terminal-spm, whose binary target is a prebuilt
# XCFramework attached to its release. The same release carries the headless VT
# runtime (libghostty-vt) that crates/craft-vt links; it is downloaded below.
# build-ghostty-vt.py / build-ghostty-native.py remain the from-source path for
# working on the Ghostty patches.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MACOS="$ROOT/macos"
BUILD="$MACOS/.build"
LOG="$BUILD/bootstrap.log"
mkdir -p "$BUILD"

# Must match the ghostty-terminal-spm tag the Xcode project pins.
# The tag, the snapshot revision suffixes and the taskhub-ghostty-* marker files inside the
# runtime keep the app's old name: they belong to the published package, and change only
# with a new tag there.
GHOSTTY_RELEASE="1.6.20260909-taskhub.1"
VT_RUNTIME_URL="https://github.com/alexcding/ghostty-terminal-spm/releases/download/$GHOSTTY_RELEASE/ghostty-vt-runtime.zip"

# Xcode pre-actions run with a bare environment; tools may live in the usual places.
export PATH="$HOME/.cargo/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Two runs per build append here; start over once it passes 1 MB.
[[ -f "$LOG" && $(stat -f %z "$LOG") -gt 1048576 ]] && : > "$LOG"

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { log "ERROR: $*"; log "Full log: $LOG"; exit 1; }

# Everything below also goes to the log so the pre-action (whose output Xcode
# hides) leaves a trail the build phase can point at.
exec > >(tee -a "$LOG") 2>&1
log "=== $(date '+%F %T') ==="

# 1. Rust (the backend and PTY helper are Rust crates; the scheme launches their binaries).
if ! command -v cargo >/dev/null 2>&1; then
  log "Rust toolchain missing; installing rustup into ~/.cargo (no shell profile changes)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    || fail "rustup install failed. Install Rust from https://rustup.rs and rerun"
  hash -r
  command -v cargo >/dev/null 2>&1 || fail "cargo not found after installing rustup"
fi

# 2. The prebuilt Ghostty VT runtime for the pinned release. A from-source build
#    (build-ghostty-vt.py) lands in the same place; delete the .release stamp's
#    directory or rerun that script to switch between the two.
RUNTIME="$BUILD/ghostty-vt/runtime"
STAMP="$BUILD/ghostty-vt/runtime.release"
if [[ ! -f "$RUNTIME/lib/libghostty-vt.a" || "$(cat "$STAMP" 2>/dev/null || true)" != "$GHOSTTY_RELEASE" ]]; then
  log "Downloading the Ghostty VT runtime $GHOSTTY_RELEASE"
  mkdir -p "$BUILD/ghostty-vt"
  ZIP="$BUILD/ghostty-vt/runtime.zip"
  curl -fsSL "$VT_RUNTIME_URL" -o "$ZIP" || fail "download failed: $VT_RUNTIME_URL"
  rm -rf "$RUNTIME" "$BUILD/ghostty-vt/runtime.tmp"
  mkdir -p "$BUILD/ghostty-vt/runtime.tmp"
  ditto -x -k "$ZIP" "$BUILD/ghostty-vt/runtime.tmp" || fail "could not unpack $ZIP"
  mv "$BUILD/ghostty-vt/runtime.tmp/runtime" "$RUNTIME" && rm -rf "$BUILD/ghostty-vt/runtime.tmp" "$ZIP"
  [[ -f "$RUNTIME/lib/libghostty-vt.a" ]] || fail "the runtime archive had no lib/libghostty-vt.a"
  echo "$GHOSTTY_RELEASE" > "$STAMP"
fi

# 3. The backend static library the app links (crates/craft-backend/src/ffi.rs) and
#    the PTY helper the shared scheme's launch arguments point at.
#
# Cargo goes through the shared normalized environment; see cargo-env.sh for why.
. "$MACOS/scripts/cargo-env.sh"

log "Building the Rust backend library and PTY helper (release)"
cargo_build build --manifest-path "$ROOT/crates/craft-backend/Cargo.toml" --release --locked || fail "craft-backend build failed"
cargo_build build --manifest-path "$ROOT/crates/craft-ptyd/Cargo.toml" --release --features terminal-snapshots --locked \
  || fail "craft-ptyd build failed"

# 4. The PTY helper inside the app bundle, where PtydHost looks when no --ptyd-path is
#    given. The scheme passes one, but a Dock or Finder relaunch of the same build does
#    not, and closing the window quits the app, so that relaunch is routine. Release
#    packaging (bundle-backend.sh) copies the same file. Only when Xcode runs us as a
#    build phase: as a scheme pre-action there is no bundle yet.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
  HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
  HELPER="$ROOT/crates/craft-ptyd/target/release/craft-ptyd"
  if ! cmp -s "$HELPER" "$HELPERS/craft-ptyd"; then
    log "Bundling the PTY helper into $CONTENTS_FOLDER_PATH/Helpers"
    mkdir -p "$HELPERS"
    # A daemon from the previous build may still be running from this path; a rename
    # gives it a fresh inode instead of overwriting the one it is executing.
    cp "$HELPER" "$HELPERS/craft-ptyd.tmp" && codesign --force --sign - "$HELPERS/craft-ptyd.tmp" \
      && mv -f "$HELPERS/craft-ptyd.tmp" "$HELPERS/craft-ptyd" || fail "could not bundle craft-ptyd"
  fi
fi

# 5. The output directory the vendored SwiftLint plugin declares but never creates.
#    CodeEditTextView and CodeEditSourceEditor each carry a SwiftLint build-tool plugin
#    (SourcePackages/checkouts/SwiftLintPlugin) whose prebuild command names
#    <workdir>/Output as its output; swiftlint writes a cache there and nothing else, so
#    every build ends with two "The folder Output doesn't exist" failures for lint runs
#    that found nothing and that this project cannot act on. Xcode checks the directory
#    after the command, so creating it first is all it takes. The plugin also honours
#    DISABLE_SWIFTLINT, but plugin evaluation does not see the target's build settings.
if [[ -n "${OBJROOT:-}" ]]; then
  PLUGINS="$OBJROOT/BuildToolPluginIntermediates"
  mkdir -p "$PLUGINS/codeedittextview.output/CodeEditTextView/SwiftLint/Output" \
           "$PLUGINS/codeeditsourceeditor.output/CodeEditSourceEditor/SwiftLint/Output"
fi

log "ready"
