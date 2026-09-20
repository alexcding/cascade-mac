#!/usr/bin/env python3
"""Build Craft's pinned native Ghostty snapshot bridge into a local Swift package."""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
from pathlib import Path


def run(*args, cwd=None, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def output(*args, cwd=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd)


def checkout(path, repository, revision):
    if not path.exists():
        run("git", "clone", "--filter=blob:none", "--no-checkout", repository, path)
        run("git", "switch", "--detach", revision, cwd=path)
    if output("git", "rev-parse", "HEAD", cwd=path).decode().strip() != revision:
        raise RuntimeError(f"Wrong revision in {path}; select a fresh --build-root.")


def changes(path):
    return hashlib.sha256(output("git", "diff", "HEAD", "--", cwd=path)).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--zig", type=Path)
    parser.add_argument("--global-cache", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("This build currently targets Apple Silicon macOS.")
    macos = Path(__file__).resolve().parents[1]
    lock_bytes = Path(__file__).with_name("ghostty-vt.lock.json").read_bytes()
    lock = json.loads(lock_bytes)
    patches = macos / "patches" / "ghostty"
    native_patch = patches / "0001-native-snapshot-import.patch"
    swift_patch = patches / "0002-swift-snapshot-import.patch"
    query_patch = patches / "0003-terminal-query-validation.patch"
    appearance_patch = patches / "0004-appkit-appearance-publication.patch"
    render_patch = patches / "0005-native-render-diagnostics.patch"
    swift_render_patch = patches / "0006-swift-render-diagnostics.patch"
    glyph_patch = patches / "0007-glyph-snapshot.patch"
    graphics_patch = patches / "0008-graphics-snapshot.patch"
    graphics_replies_patch = patches / "0009-native-graphics-replies.patch"
    appearance_native_patch = patches / "0010-native-appearance.patch"
    appearance_swift_patch = patches / "0011-swift-appearance.patch"
    fingerprint = hashlib.sha256(lock_bytes + native_patch.read_bytes() + swift_patch.read_bytes() + query_patch.read_bytes()
                                 + appearance_patch.read_bytes() + render_patch.read_bytes()
                                 + swift_render_patch.read_bytes() + glyph_patch.read_bytes() + graphics_patch.read_bytes() + graphics_replies_patch.read_bytes() + appearance_native_patch.read_bytes() + appearance_swift_patch.read_bytes()).hexdigest()
    root = (args.build_root or macos / ".build" / "ghostty-native").resolve()
    root.mkdir(parents=True, exist_ok=True)
    zig = (args.zig or macos / ".build" / "ghostty-vt" / "tools" /
           f"zig-aarch64-macos-{lock['zigVersion']}" / "zig").resolve()
    if not zig.is_file():
        parser.error("Run build-ghostty-vt.py first, or pass --zig for the pinned toolchain.")
    if output(zig, "version").decode().strip() != lock["zigVersion"]:
        parser.error("Zig version does not match the lock file.")
    source, package = root / "source", root / "package"
    checkout(source, lock["repository"], lock["revision"])
    checkout(package, lock["wrapperRepository"], lock["wrapperRevision"])
    cache = root / "cache"
    global_cache = (args.global_cache or cache / "global").resolve()
    env = dict(os.environ, PATH=str(zig.parent) + os.pathsep + os.environ.get("PATH", ""),
               ZIG_GLOBAL_CACHE_DIR=str(global_cache), ZIG_LOCAL_CACHE_DIR=str(cache / "native"),
               CLANG_MODULE_CACHE_PATH=str(cache / "clang"))
    prepared = root / "prepared.json"
    needs_preparation = not prepared.exists()
    if prepared.exists():
        state = json.loads(prepared.read_text())
        if state.get("format") != 2:
            parser.error("This build predates complete patch tracking; select a fresh --build-root.")
        if state.get("source") != changes(source) or state.get("package") != changes(package):
            parser.error("Prepared source was edited outside the build script; select a fresh --build-root.")
        if state.get("inputs") != fingerprint:
            # Only undo the exact generated changes whose hashes were recorded.
            # Unexpected user edits above stop the build instead of being erased.
            for directory in [source, package]:
                diff = output("git", "diff", "--binary", "HEAD", "--", cwd=directory)
                if diff:
                    subprocess.run(["git", "apply", "--reverse"], input=diff, cwd=directory, check=True)
            needs_preparation = True
    if needs_preparation:
        run("git", "diff", "--exit-code", "HEAD", "--", cwd=source)
        run("git", "diff", "--exit-code", "HEAD", "--", cwd=package)
        run("zsh", package / "Script" / "apply-patches.sh", source, cwd=package, env=env)
        for directory, patch in [(source, native_patch), (source, query_patch), (package, swift_patch), (package, appearance_patch),
                                 (source, render_patch), (package, swift_render_patch), (source, glyph_patch), (source, graphics_patch), (source, graphics_replies_patch), (source, appearance_native_patch), (package, appearance_swift_patch)]:
            run("git", "apply", "--check", patch, cwd=directory)
            run("git", "apply", patch, cwd=directory)
        shutil.copy2(package / "Package.local.swift", package / "Package.swift")
        # Upstream patches create new files. Stage generated changes in these
        # private checkouts so fingerprints and reversal include those files too.
        for directory in [source, package]:
            run("git", "add", "--all", cwd=directory)
        prepared.write_text(json.dumps({"format": 2, "inputs": fingerprint, "source": changes(source),
                                        "package": changes(package)}, indent=2) + "\n")
    run(zig, "build", "-Doptimize=ReleaseFast", "-Dapp-runtime=none", "-Demit-exe=false",
        "-Demit-xcframework=false", "-Demit-macos-app=false", "-Demit-docs=false",
        "-Dsentry=false", "-Dcustom-shaders=false", "-Dinspector=false",
        "-Dtarget=aarch64-macos", cwd=source, env=env)
    archive = source / "zig-out" / "lib" / "libghostty.a"
    if not archive.is_file():
        parser.error("The native build did not produce its static archive.")
    # Standard single-slice XCFramework metadata around the actual arm64 archive.
    # SwiftPM verifies and consumes this layout; no Mach-O architecture rewriting.
    xcframework = package / "BinaryTarget" / "GhosttyKit.xcframework"
    slice_dir = xcframework / "macos-arm64"
    headers = slice_dir / "Headers" / "libghostty"
    headers.mkdir(parents=True, exist_ok=True)
    shutil.copy2(archive, slice_dir / "libghostty.a")
    shutil.copy2(source / "include" / "ghostty.h", headers / "ghostty.h")
    (headers / "module.modulemap").write_text('module libghostty {\n    umbrella header "ghostty.h"\n    export *\n}\n')
    with (xcframework / "Info.plist").open("wb") as file:
        plistlib.dump({"AvailableLibraries": [{"LibraryIdentifier": "macos-arm64",
            "LibraryPath": "libghostty.a", "HeadersPath": "Headers",
            "SupportedArchitectures": ["arm64"], "SupportedPlatform": "macos"}],
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}, file)
    (root / "built.json").write_text(json.dumps({"revision": lock["revision"],
        "wrapperRevision": lock["wrapperRevision"], "inputs": fingerprint,
        "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest()}, indent=2) + "\n")
    print(f"Pinned native snapshot package: {package}")


if __name__ == "__main__":
    main()
