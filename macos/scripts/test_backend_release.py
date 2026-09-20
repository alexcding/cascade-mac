import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("backend_release", Path(__file__).with_name("backend-release.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BackendReleaseTests(unittest.TestCase):
    def test_identity_is_repeatable_and_changes_for_code_dependencies_or_app_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src" / "server").mkdir(parents=True)
            source = root / "src" / "server" / "app.js"
            source.write_text("first")
            (root / "package.json").write_text("{}")
            lock = root / "package-lock.json"
            lock.write_text("{}")
            info_path = root / "Info.plist"
            info = {"CFBundleIdentifier": "fixture", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}
            info_path.write_bytes(plistlib.dumps(info))
            first = module.release_manifest(root, info_path)
            (root / "release.json").write_text("previous generated identity")
            (root / "node_modules").mkdir()
            (root / "node_modules" / "generated").write_text("not a source input")
            self.assertEqual(first, module.release_manifest(root, info_path))
            source.write_text("second")
            second = module.release_manifest(root, info_path)
            self.assertNotEqual(first["id"], second["id"])
            lock.write_text('{"lockfileVersion":3}')
            third = module.release_manifest(root, info_path)
            self.assertNotEqual(second["id"], third["id"])
            info["CFBundleVersion"] = "2"
            info_path.write_bytes(plistlib.dumps(info))
            self.assertNotEqual(third["id"], module.release_manifest(root, info_path)["id"])
            source.unlink()
            source.symlink_to(lock)
            with self.assertRaisesRegex(ValueError, "symlinks"):
                module.release_manifest(root, info_path)


if __name__ == "__main__":
    unittest.main()
