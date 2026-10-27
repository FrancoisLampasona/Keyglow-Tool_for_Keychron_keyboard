#!/usr/bin/env python3
"""Preview or clean only known generated outputs; preserve firmware and user data."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
APP_PATHS = (
    "build/Tastiera-v04-backup.app", "build/Tastiera-v05-backup.app",
    "build/Tastiera-v06-backup.app", "build/Relocation Test/Keyglow.app",
    "build/Keyglow HID Probe.app", "build/Keyglow Bluetooth Diagnostics.app",
    "dist/Tastiera.app",
)
APP_GLOBS = ("build/keyglow-previous.*/Keyglow.app", "build/hid-probe-stage.*/Keyglow HID Probe.app")
CACHE_PATHS = (
    "build/swift-cache", "build/swift-module-cache", "build/swift-onboarding-cache",
    "build/diagnostics/radio-version/module-cache", "build/tests",
    "build/onboarding-tests", "build/protocol-tests", "build/test-energy",
    "build/test-via", "build/test-workspace",
    "build/Keyglow.iconset", "build/Tastiera.iconset", "build/Keyglow.icns",
)
KEEP = ("dist/Keyglow.app", "dist/firmware", "build/ota-integration", "build/bt-probe",
        "build/qmk-firmware", "build/qmk-venv", "build/toolchains", "build/recovery", "research")
KNOWN_IDS = {"local.tastiera.bluetooth-prototype", "local.keyglow.hid-probe", "local.keyglow.bluetooth-diagnostics"}


def checked_path(root: Path, path: Path) -> Path:
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Refusing symlink path: {relative}")
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path leaves checkout: {relative}")
    return path


def byte_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.lstat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def app_info(bundle: Path) -> tuple[dict, Path]:
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") not in KNOWN_IDS:
        raise ValueError(f"Unrecognized application: {bundle.name}")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        raise ValueError(f"Invalid executable name: {bundle.name}")
    binary = bundle / "Contents/MacOS" / executable
    if not binary.is_file() or binary.is_symlink():
        raise ValueError(f"Missing executable: {bundle.name}")
    return info, binary


def candidates(root: Path, scope: str) -> list[dict]:
    result = []
    if scope in ("all", "apps"):
        paths = {root / p for p in APP_PATHS}
        for pattern in APP_GLOBS:
            paths.update(root.glob(pattern))
        for path in sorted(paths):
            checked_path(root, path)
            if path.exists():
                info, binary = app_info(path)
                result.append({"path": str(path.relative_to(root)), "action": "archive-app",
                               "bytes": byte_size(path), "version": info.get("CFBundleShortVersionString", "unknown"),
                               "executableSHA256": digest(binary)})
    if scope in ("all", "caches"):
        for relative in CACHE_PATHS:
            path = checked_path(root, root / relative)
            if path.exists():
                result.append({"path": relative, "action": "remove-generated", "bytes": byte_size(path)})
    return result


def verify_archive(bundle: Path, archive: Path) -> None:
    """Check every archived source file, including the signed binary and resources."""
    with zipfile.ZipFile(archive) as zipped:
        bad = zipped.testzip()
        if bad:
            raise ValueError(f"Invalid archive member: {bad}")
        for source in bundle.rglob("*"):
            if source.is_symlink():
                expected = str(source.readlink()).encode()
            elif source.is_file():
                expected = source.read_bytes()
            else:
                continue
            entry = f"{bundle.name}/{source.relative_to(bundle).as_posix()}"
            if zipped.read(entry) != expected:
                raise ValueError(f"Archive mismatch: {entry}")


def archive_app(root: Path, bundle: Path) -> Path:
    checked_path(root, bundle)
    info, binary = app_info(bundle)
    recovery = checked_path(root, root / "build/recovery/apps")
    recovery.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    name = "".join(c if c.isalnum() or c in "-_." else "-" for c in bundle.stem)
    target = recovery / f"{name}-{stamp}-{digest(binary)[:12]}.zip"
    with tempfile.TemporaryDirectory(prefix="archive-", dir=recovery) as temp:
        pending = Path(temp) / "bundle.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(pending)], check=True)
        verify_archive(bundle, pending)
        pending.chmod(0o600)
        pending.replace(target)
    # Write recovery metadata before the caller is allowed to remove anything.
    metadata = target.with_suffix(".json")
    metadata.write_text(json.dumps({
        "originalPath": str(bundle.relative_to(root)), "archive": target.name,
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
        "executableSHA256": digest(binary), "archiveSHA256": digest(target),
    }, indent=2) + "\n")
    metadata.chmod(0o600)
    return target


def apply_plan(root: Path, plan: list[dict]) -> list[dict]:
    # Inspect processes once before any removal, not after creating a half-clean tree.
    processes = {line.strip() for line in subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()}
    for item in plan:
        if item["action"] == "archive-app":
            path = root / item["path"]
            _, binary = app_info(path)
            if str(binary) in processes:
                raise RuntimeError(f"Close the obsolete application before cleanup: {item['path']}")
    results = []
    for item in plan:
        path = checked_path(root, root / item["path"])
        if item["action"] == "archive-app":
            _, binary = app_info(path)
            if digest(binary) != item["executableSHA256"]:
                raise RuntimeError(f"Application changed since inventory: {item['path']}")
            archive = archive_app(root, path)
            if LSREGISTER.exists():
                subprocess.run([str(LSREGISTER), "-u", str(path)], check=True)
            shutil.rmtree(path)
            results.append({**item, "archive": str(archive.relative_to(root))})
            parent = path.parent
            if parent.name.startswith(("keyglow-previous.", "hid-probe-stage.")) or parent.name == "Relocation Test":
                if not any(parent.iterdir()):
                    parent.rmdir()
        else:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            results.append(item)
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("clean", "archive-current"), default="clean")
    parser.add_argument("--scope", choices=("all", "apps", "caches"), default="all")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="Apply the printed allowlist; default only inventories")
    mode.add_argument("--dry-run", action="store_false", dest="apply", help="Only print the allowlist (default)")
    parser.set_defaults(apply=False)
    args = parser.parse_args()
    if args.command == "archive-current":
        # Build helper: never removes/replaces the currently installed bundle.
        print(archive_app(ROOT, ROOT / "dist/Keyglow.app"))
        return
    plan = candidates(ROOT, args.scope)
    report = {"mode": "apply" if args.apply else "dry-run", "preserved": KEEP,
              "candidateBytes": sum(item["bytes"] for item in plan), "items": plan}
    if args.apply:
        report["items"] = apply_plan(ROOT, plan)
        journal = ROOT / "build/recovery/cleanup-history"
        journal.mkdir(parents=True, exist_ok=True, mode=0o700)
        record = journal / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".json")
        record.write_text(json.dumps(report, indent=2) + "\n")
        record.chmod(0o600)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
