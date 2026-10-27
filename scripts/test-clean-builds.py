#!/usr/bin/env python3
"""Cleanup regression checks on disposable synthetic app bundles only."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location("clean_builds", Path(__file__).with_name("clean-builds.py"))
clean = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clean)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keyglow-cleanup-test-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def app(self, relative):
        bundle = self.root / relative
        binary = bundle / "Contents/MacOS/Keyglow"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"synthetic executable - never launched")
        binary.chmod(0o755)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.tastiera.bluetooth-prototype",
            "CFBundleExecutable": "Keyglow", "CFBundleShortVersionString": "test",
        }))
        (bundle / "Contents/Resources").mkdir()
        (bundle / "Contents/Resources/example.txt").write_text("synthetic resource")
        return bundle

    def test_allowlist_preserves_current_private_firmware_and_unknown_bundles(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        current = self.app("dist/Keyglow.app")
        unknown = self.app("build/Unknown.app")
        private = self.root / "build/ota-integration/private/fixture.bin"
        private.parent.mkdir(parents=True)
        private.write_bytes(b"synthetic private fixture")
        paths = [item["path"] for item in clean.candidates(self.root, "all")]
        self.assertEqual(paths, [str(old.relative_to(self.root))])
        self.assertTrue(current.exists() and unknown.exists() and private.exists())

    def test_refuses_symlink_candidate(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "build").mkdir()
        (self.root / "build/swift-cache").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            clean.candidates(self.root, "caches")

    def test_verified_archive_then_removal_and_parent_cleanup(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        plan = clean.candidates(self.root, "apps")
        with patch.object(clean.subprocess, "check_output", return_value=""), patch.object(clean, "LSREGISTER", self.root / "missing-lsregister"):
            results = clean.apply_plan(self.root, plan)
        self.assertFalse(old.exists())
        self.assertFalse(old.parent.exists())
        archive = self.root / results[0]["archive"]
        self.assertTrue(archive.with_suffix(".json").is_file())
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.read("Keyglow.app/Contents/Resources/example.txt"), b"synthetic resource")

    def test_archive_failure_keeps_original(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        plan = clean.candidates(self.root, "apps")
        with patch.object(clean.subprocess, "check_output", return_value=""), patch.object(clean, "archive_app", side_effect=ValueError("archive failed")):
            with self.assertRaises(ValueError):
                clean.apply_plan(self.root, plan)
        self.assertTrue(old.exists())

    def test_running_obsolete_app_blocks_all_removal(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        plan = clean.candidates(self.root, "apps")
        with patch.object(clean.subprocess, "check_output", return_value=str(old / "Contents/MacOS/Keyglow") + "\n"):
            with self.assertRaises(RuntimeError):
                clean.apply_plan(self.root, plan)
        self.assertTrue(old.exists())

    def test_corrupt_archive_is_rejected(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        archive = clean.archive_app(self.root, old)
        (old / "Contents/Resources/example.txt").write_text("changed after archive")
        with self.assertRaises(ValueError):
            clean.verify_archive(old, archive)

    def test_changed_binary_after_plan_is_not_removed(self):
        old = self.app("build/keyglow-previous.fixture/Keyglow.app")
        plan = clean.candidates(self.root, "apps")
        (old / "Contents/MacOS/Keyglow").write_bytes(b"new build")
        with patch.object(clean.subprocess, "check_output", return_value=""):
            with self.assertRaises(RuntimeError):
                clean.apply_plan(self.root, plan)
        self.assertTrue(old.exists())


if __name__ == "__main__":
    unittest.main()
