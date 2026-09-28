#!/usr/bin/env python3
"""Vendor VS Code's language table into macos/Resources/VSCodeLanguages.bundle.

usage: vendor-vscode-languages.py <vscode-checkout>

A VS Code file icon theme gives most languages their icon by language ID, which comes from VS
Code, not the theme. The bundle carries the file extensions and names VS Code's built-in languages
claim, read from `extensions/*/package.json` in an MIT checkout of microsoft/vscode, with its
licence. The bundle is regenerated whole: rerun this rather than editing it.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys

OUT = Path(__file__).resolve().parent.parent / "Resources" / "VSCodeLanguages.bundle"


def languages(vscode: Path):
    extensions, filenames = {}, {}
    for package in sorted(vscode.glob("extensions/*/package.json")):
        for language in json.loads(package.read_text()).get("contributes", {}).get("languages", []):
            for claimed, table in ((language.get("extensions", []), extensions), (language.get("filenames", []), filenames)):
                for key in claimed:
                    key = key.lower().removeprefix(".")
                    if table.setdefault(key, language["id"]) != language["id"]:
                        raise ValueError(f"{key} is claimed by {table[key]} and {language['id']}")
    return {"extensions": extensions, "filenames": filenames}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[2])
    vscode = Path(sys.argv[1])
    table = languages(vscode)
    if not table["extensions"]:
        sys.exit(f"{vscode} has no extensions/*/package.json claiming languages")
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    (OUT / "languages.json").write_text(json.dumps(table, sort_keys=True, separators=(",", ":")))
    shutil.copyfile(vscode / "LICENSE.txt", OUT / "LICENSE.txt")
    commit = subprocess.run(["git", "-C", str(vscode), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip() or "unknown"
    (OUT / "SOURCES.txt").write_text(f"languages: microsoft/vscode {commit}\n")
    print(f"{len(table['extensions']) + len(table['filenames'])} language entries from microsoft/vscode {commit}")


if __name__ == "__main__":
    main()
