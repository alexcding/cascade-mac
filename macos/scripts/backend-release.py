#!/usr/bin/env python3
"""Record a deterministic identity for packaged app metadata and backend inputs."""
import hashlib
import json
from pathlib import Path
import plistlib
import sys


def release_manifest(backend: Path, info_path: Path):
    info = plistlib.loads(info_path.read_bytes())
    app = {key: info[key] for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
    files = sorted((backend / "src").rglob("*")) + [backend / "package.json", backend / "package-lock.json"]
    inputs = []
    for file in files:
        if file.is_symlink():
            raise ValueError("Release inputs must not contain symlinks")
        if file.is_file():
            inputs.append([file.relative_to(backend).as_posix(), hashlib.sha256(file.read_bytes()).hexdigest()])
    identity = json.dumps({"format": 1, "app": app, "files": sorted(inputs)}, sort_keys=True, separators=(",", ":"))
    return {"format": 1, "id": hashlib.sha256(identity.encode()).hexdigest(), "app": app}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: backend-release.py BACKEND_DIR APP_INFO_PLIST")
    backend = Path(sys.argv[1])
    (backend / "release.json").write_text(json.dumps(release_manifest(backend, Path(sys.argv[2])), indent=2) + "\n")
