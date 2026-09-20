#!/usr/bin/env python3
"""Check the arm64 app's direct @rpath dependencies resolve inside its bundle.

This is a packaging preflight, not a substitute for launching the final app or
checking transitive dependencies, signatures and supported OS versions.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def check(app: Path):
    contents = app.resolve() / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    commands = subprocess.check_output(["/usr/bin/otool", "-arch", "arm64", "-l", str(executable)], text=True)
    libraries = subprocess.check_output(["/usr/bin/otool", "-arch", "arm64", "-L", str(executable)], text=True)
    paths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)", commands)
    dependencies = sorted(set(re.findall(r"^\s*(@rpath/.+?) \(", libraries, re.MULTILINE)))
    for dependency in dependencies:
        candidates = []
        for raw in paths:
            if raw == "@loader_path" or raw.startswith("@loader_path/"):
                base = executable.parent / raw.removeprefix("@loader_path").lstrip("/")
            elif raw == "@executable_path" or raw.startswith("@executable_path/"):
                base = executable.parent / raw.removeprefix("@executable_path").lstrip("/")
            elif raw.startswith("/"):
                base = Path(raw)
            else:
                continue
            candidates.append((base / dependency.removeprefix("@rpath/")).resolve())
        if not any(file.is_relative_to(contents) and file.is_file() for file in candidates):
            raise ValueError(f"{dependency} does not resolve inside the app via its LC_RPATH entries: {paths}")
    print(f"Verified {len(dependencies)} direct @rpath dependencies inside {app}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-runtime-frameworks.py APP_PATH")
    try:
        check(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Runtime framework preflight failed: {error}")
