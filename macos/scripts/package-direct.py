#!/usr/bin/env python3
"""Stage a bundled Craft app for local review or signed direct distribution.

Requires a completed Xcode build followed by bundle-backend.sh. Never changes the
input app, installs it, publishes a feed, or accesses application data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def mach_o(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open("rb") as file:
        return file.read(4) in {
            b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
            b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
            b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
        }


def sign_app(app, identity, local):
    config = Path(__file__).resolve().parents[1] / "Resources" / "Configs"
    common = ["codesign", "--force", "--sign", identity]
    if not local:
        common += ["--options", "runtime", "--timestamp"]
    # Sign leaf binaries before their containing bundles. Preserve Sparkle's
    # declared entitlements while giving all embedded code the same signing team.
    binaries = [path for path in app.rglob("*") if mach_o(path)]
    for binary in sorted(binaries, key=lambda p: (-len(p.parts), str(p))):
        entitlements = []
        if binary == app / "Contents/MacOS/Craft":
            entitlements = ["--entitlements", config / "Craft.entitlements"]
        elif "Frameworks" in binary.parts:
            entitlements = ["--preserve-metadata=entitlements"]
        run(*common, *entitlements, binary)
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink()
               and p.suffix in {".framework", ".xpc", ".app", ".bundle"}]
    for bundle in sorted(bundles, key=lambda p: (-len(p.parts), str(p))):
        # Resource-only bundles have no executable and need no code signature.
        info_paths = [bundle / "Contents/Info.plist", bundle / "Resources/Info.plist", bundle / "Info.plist"]
        infos = [p for p in info_paths if p.is_file()]
        if not infos or not plistlib.loads(infos[0].read_bytes()).get("CFBundleExecutable"):
            continue
        run(*common, "--preserve-metadata=entitlements", bundle)
    run(*common, "--entitlements", config / "Craft.entitlements", app)
    run("codesign", "--verify", "--deep", "--strict", app)


def archive(app, target):
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, target)


def notarize(artifact, profile):
    response = subprocess.check_output(["xcrun", "notarytool", "submit", str(artifact),
                                        "--keychain-profile", profile, "--wait", "--output-format", "json"], text=True)
    result = json.loads(response)
    if result.get("status") != "Accepted":
        raise RuntimeError(f"Notarization {result.get('id', '')}: {result.get('status', 'unknown')}")


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory; existing output is never replaced")
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--local", action="store_true", help="Ad-hoc app for local review; no Apple submission")
    signing.add_argument("--identity", help="Developer ID Application signing identity")
    parser.add_argument("--notary-profile", help="Existing notarytool Keychain profile; required for distribution")
    args = parser.parse_args()
    app = args.app.resolve()
    destination = args.output.resolve()
    if args.local and args.notary_profile:
        parser.error("Local packaging does not submit to Apple")
    if not args.local and (not args.identity.startswith("Developer ID Application:") or not args.notary_profile):
        parser.error("Distribution needs a Developer ID Application identity and a notary Keychain profile")
    if destination == app or app in destination.parents:
        parser.error("Output must be outside the input app")
    if destination.exists():
        parser.error("Choose a new output directory; existing artifacts are preserved")
    if not app.is_dir() or app.suffix != ".app":
        parser.error("--app must be a completed Craft.app bundle")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.alexcding.craft":
        parser.error("Unexpected application bundle identity")
    if not args.local and info.get("CraftBuildConfiguration") != "Release":
        parser.error("Build the Release configuration before preparing a distribution")
    # The backend is linked into the app binary (crates/craft-backend/src/ffi.rs);
    # only the PTY helper ships as a separate executable.
    for relative in ["Contents/Helpers/craft-ptyd"]:
        if not (app / relative).is_file():
            parser.error("Run bundle-backend.sh before packaging: missing " + relative)
    if (app / "Contents/Helpers/craft-backend").exists():
        parser.error("Stale backend helper remains; rerun bundle-backend.sh: Contents/Helpers/craft-backend")
    for relative in ["Contents/Helpers/craft-node", "Contents/Resources/backend"]:
        if (app / relative).exists():
            parser.error("Legacy Node bundle remains; rerun bundle-backend.sh: " + relative)
    # The working-changes diff page is the one bundled page. Its scripts may ship, byte for byte
    # as in Resources/DiffPage; any other JavaScript in the bundle is a regression.
    diff_page = Path(__file__).resolve().parents[1] / "Resources" / "DiffPage"
    for script in (p for p in app.rglob("*") if p.suffix.lower() in {".js", ".mjs", ".cjs"}):
        source = diff_page / script.name
        if (script.parent != app / "Contents/Resources" or not source.is_file()
                or source.read_bytes() != script.read_bytes()):
            parser.error("Unexpected bundled JavaScript: " + str(script.relative_to(app)))
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Publish the directory only after every packaging/signing operation succeeds.
    with tempfile.TemporaryDirectory(prefix=".craft-package-", dir=destination.parent) as temporary:
        stage = Path(temporary)
        result = stage / "result"
        result.mkdir()
        staged_app = result / "Craft.app"
        run("ditto", app, staged_app)
        sign_app(staged_app, args.identity or "-", args.local)
        zip_path = result / "Craft.zip"
        archive(staged_app, zip_path)
        if not args.local:
            notarize(zip_path, args.notary_profile)
            run("xcrun", "stapler", "staple", staged_app)
            run("xcrun", "stapler", "validate", staged_app)
            zip_path.unlink()
            archive(staged_app, zip_path)
        disk = stage / "disk"
        disk.mkdir()
        run("ditto", staged_app, disk / "Craft.app")
        (disk / "Applications").symlink_to("/Applications", target_is_directory=True)
        dmg = result / "Craft.dmg"
        run("hdiutil", "create", "-volname", "Craft", "-srcfolder", disk,
            "-format", "UDZO", "-ov", dmg)
        if not args.local:
            run("codesign", "--sign", args.identity, "--timestamp", dmg)
            notarize(dmg, args.notary_profile)
            run("xcrun", "stapler", "staple", dmg)
            run("xcrun", "stapler", "validate", dmg)
        manifest = {"bundleID": info["CFBundleIdentifier"],
                    "backendRuntime": "rust-embedded",
                    "backendSHA256": digest(staged_app / "Contents/MacOS/Craft"),
                    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                    "distribution": "local-ad-hoc" if args.local else "developer-id-notarized",
                    "artifacts": {p.name: {"bytes": p.stat().st_size,
                                           "sha256": digest(p)}
                                  for p in [zip_path, dmg]}}
        (result / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.move(result, destination)
    print(f"Prepared {destination / 'Craft.app'}")
    print("No update feed was published. Sparkle archives still require your Ed25519 signature before publication.")


if __name__ == "__main__":
    main()
