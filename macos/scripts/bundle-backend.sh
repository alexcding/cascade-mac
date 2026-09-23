#!/usr/bin/env bash
# Run after the Xcode build. Produces an ad-hoc signed development bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?usage: bash macos/scripts/bundle-backend.sh /absolute/path/Craft.app}"
test -d "$APP/Contents/MacOS"
python3 "$ROOT/macos/scripts/check-runtime-frameworks.py" "$APP"

# Same normalized cargo environment as the Xcode build, so this reuses what
# bootstrap.sh already compiled instead of invalidating it (see cargo-env.sh).
. "$ROOT/macos/scripts/cargo-env.sh"
cargo_build build --locked --release --manifest-path "$ROOT/crates/craft-backend/Cargo.toml"
cargo_build build --locked --release --manifest-path "$ROOT/crates/craft-ptyd/Cargo.toml" --features terminal-snapshots

mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
cp "$ROOT/crates/craft-ptyd/target/release/craft-ptyd" "$APP/Contents/Helpers/craft-ptyd"
# The backend is linked into the app binary now; drop a helper left by an older bundle.
rm -f "$APP/Contents/Helpers/craft-backend" "$APP/Contents/Helpers/craft-node" "$APP/Contents/Resources/Licenses/Node-LICENSE"

# The native toolbar's provider artwork. The app is native Swift over the Rust
# backend: no JavaScript runtime ships with it, only the diff page's own scripts.
rm -rf "$APP/Contents/Resources/CraftImages" "$APP/Contents/Resources/backend"
mkdir -p "$APP/Contents/Resources/CraftImages"
cp -R "$ROOT/macos/Resources/ProviderImages/." "$APP/Contents/Resources/CraftImages/"

cp "$ROOT/macos/licenses/Sparkle-LICENSE" "$APP/Contents/Resources/Licenses/Sparkle-LICENSE"
# The GhosttyTerminal package checkout SwiftPM made for the Xcode build (the
# derived-data path the README's release build uses), unless one is given.
GHOSTTY_PKG="${CRAFT_GHOSTTY_PACKAGE:-$ROOT/macos/.build/xcode/SourcePackages/checkouts/ghostty-terminal-spm}"
test -f "$GHOSTTY_PKG/LICENSE-ghostty" || { echo "GhosttyTerminal checkout not found at $GHOSTTY_PKG; set CRAFT_GHOSTTY_PACKAGE" >&2; exit 1; }
cp "$GHOSTTY_PKG/LICENSE-ghostty" "$APP/Contents/Resources/Licenses/Ghostty-LICENSE"
cp "$GHOSTTY_PKG/LICENSE" "$APP/Contents/Resources/Licenses/GhosttyTerminal-LICENSE"
cp "$GHOSTTY_PKG/Sources/GhosttyTheme/LICENSE" "$APP/Contents/Resources/Licenses/GhosttyTheme-LICENSE"

# The file editor: CodeEditSourceEditor and what it links. Each is copied from the checkout SwiftPM
# made, next to GhosttyTerminal's. CodeEditLanguages and CodeEditSymbols publish no license file at
# their pinned versions (0.1.20, 0.2.3); they are CodeEditApp's, whose other packages are MIT, but
# that is unconfirmed — settle it with upstream before a public release.
PACKAGES="$(dirname "$GHOSTTY_PKG")"
for entry in CodeEditSourceEditor:LICENSE.md CodeEditTextView:LICENSE.md TextFormation:LICENSE TextStory:LICENSE \
             Rearrange:LICENSE SwiftTreeSitter:LICENSE tree-sitter:LICENSE swift-collections:LICENSE.txt; do
  name="${entry%%:*}"
  test -f "$PACKAGES/$name/${entry#*:}" || { echo "No license for $name at $PACKAGES/$name" >&2; exit 1; }
  cp "$PACKAGES/$name/${entry#*:}" "$APP/Contents/Resources/Licenses/$name-LICENSE"
done

codesign --force --sign - "$APP/Contents/Helpers/craft-ptyd"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Bundled Rust backend and PTY daemon: $APP"
