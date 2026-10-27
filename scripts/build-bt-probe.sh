#!/bin/sh
# Build only. This script never launches the diagnostics or touches the keyboard.
set -eu
cd "$(dirname "$0")/.."
bundle="$PWD/build/Keyglow HID Probe.app"
output="${KEYGLOW_PROBE_RESULT_PATH:-$PWD/research/bluetooth-v08/probe/private/host-result.json}"
mkdir -p "$PWD/build/swift-cache"
stage_root="$(mktemp -d "$PWD/build/hid-probe-stage.XXXXXX")"
stage_bundle="$stage_root/Keyglow HID Probe.app"
mkdir -p "$stage_bundle/Contents/MacOS"
xcrun swiftc -swift-version 6 -parse-as-library -O -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework AppKit -framework SwiftUI -framework IOKit \
  macOS/Diagnostics/Probe/*.swift macOS/Sources/HIDTransport.swift macOS/Sources/RGBProtocol.swift \
  macOS/Sources/VIAUSBTransport.swift macOS/Sources/VIAProtocol.swift \
  -o "$stage_bundle/Contents/MacOS/KeyglowHIDProbe"
python3 - "$stage_bundle" "$output" <<'PY'
import plistlib,sys
from pathlib import Path
output=Path(sys.argv[2])
if not output.is_absolute(): raise SystemExit('Result path must be absolute')
plist={'CFBundleIdentifier':'local.keyglow.hid-probe','CFBundleName':'Keyglow HID Probe',
       'CFBundleDisplayName':'Keyglow HID Probe','CFBundleExecutable':'KeyglowHIDProbe',
       'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.2.0','CFBundleVersion':'2',
       'LSMinimumSystemVersion':'13.0','NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,
       'KeyglowProbeResultPath':str(output),
       'KeyglowProbeExpectedFirmware':'v1.1.1 2026-10-26-23:17:58'}
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
codesign --force --sign - "$stage_bundle"
codesign --verify --strict "$stage_bundle"
if [ "${1:-}" != --replace-closed ]; then
  process_status=0
  pgrep -x KeyglowHIDProbe >/dev/null 2>&1 || process_status=$?
  if [ "$process_status" -ne 1 ]; then
    python3 - "$stage_bundle" <<'PY'
import importlib.util, shutil, sys
from pathlib import Path
sys.dont_write_bytecode = True
root = Path.cwd()
spec = importlib.util.spec_from_file_location('clean_builds', root / 'scripts/clean-builds.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
candidate = Path(sys.argv[1])
archive = helper.archive_app(root, candidate)
shutil.rmtree(candidate.parent)
print('The probe is running or process status is unavailable; its bundle was not replaced.')
print('Signed candidate archived without another Launchpad entry:', archive)
PY
    printf '%s\n' 'After confirming the old app is closed, rerun with --replace-closed to publish a fresh build.'
    exit 0
  fi
fi
python3 - "$stage_bundle" "$bundle" <<'PY'
import ctypes, importlib.util, os, shutil, sys
from pathlib import Path
sys.dont_write_bytecode = True
root = Path.cwd()
spec = importlib.util.spec_from_file_location('clean_builds', root / 'scripts/clean-builds.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
candidate,destination=map(Path,sys.argv[1:])
if destination.exists():
    archive = helper.archive_app(root, destination)
    # Darwin RENAME_SWAP atomically publishes the new complete signed bundle.
    # Archive verification completed before changing either bundle.
    libc=ctypes.CDLL(None,use_errno=True)
    swap=libc.renamex_np
    swap.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
    swap.restype=ctypes.c_int
    if swap(os.fsencode(candidate),os.fsencode(destination),2) != 0:
        raise OSError(ctypes.get_errno(),'Atomic bundle swap failed; signed candidate retained')
    shutil.rmtree(candidate)
    candidate.parent.rmdir()
    print('Previous signed build archived:',archive)
else:
    os.rename(candidate,destination)
    candidate.parent.rmdir()
PY
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
