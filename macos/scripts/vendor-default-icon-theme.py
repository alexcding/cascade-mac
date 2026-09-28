#!/usr/bin/env python3
"""Vendor the app's default file icon theme into macos/Resources/DefaultIconTheme.vsix.

usage: vendor-default-icon-theme.py [publisher.name]

Downloads the extension's latest package from Open VSX (default: vscode-icons-team.vscode-icons)
and keeps it as it is; the package carries its own licence. The app installs it on first launch
and people may remove it like any theme. If the extension or its theme ID changes, change
`IconThemeLibrary.bundledTheme` to match.
"""
import io
import json
from pathlib import Path
import sys
import urllib.request
import zipfile

OUT = Path(__file__).resolve().parent.parent / "Resources" / "DefaultIconTheme.vsix"


def main():
    if len(sys.argv) > 2:
        sys.exit(__doc__.strip().splitlines()[2])
    extension = sys.argv[1] if len(sys.argv) == 2 else "vscode-icons-team.vscode-icons"
    namespace, name = extension.split(".", 1)
    with urllib.request.urlopen(f"https://open-vsx.org/api/{namespace}/{name}") as response:
        listing = json.load(response)
    with urllib.request.urlopen(listing["files"]["download"]) as response:
        package = response.read()
    info = json.loads(zipfile.ZipFile(io.BytesIO(package)).read("extension/package.json"))
    themes = [theme["id"] for theme in info.get("contributes", {}).get("iconThemes", [])]
    if not themes:
        sys.exit(f"{extension} {listing['version']} contributes no icon theme")
    OUT.write_bytes(package)
    print(f"{extension} {listing['version']} ({listing.get('license', 'no licence field')}), "
          f"{len(package) >> 10} KB; its theme is {extension}/{themes[0]}")


if __name__ == "__main__":
    main()
