#!/usr/bin/env python3
"""Sign with an explicit identity, the configured local identity, or ad hoc.

Never creates credentials, changes trust settings, or edits macOS permissions.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

CONFIG = Path.home() / 'Library/Application Support/Keyglow/Development/signing.json'


def run(*args):
    subprocess.run(args, check=True)


def requirement(bundle):
    result = subprocess.run(['codesign', '-d', '-r-', str(bundle)], check=True, capture_output=True, text=True)
    for line in (result.stdout + result.stderr).splitlines():
        if 'designated =>' in line:
            return line.split('designated =>', 1)[1].strip()
    raise RuntimeError('Missing designated requirement')


def local_requirement(identifier, fingerprint):
    if not re.fullmatch(r'[A-Za-z0-9.-]+', identifier) or not re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint):
        raise ValueError('Invalid signing identity configuration')
    return f'identifier "{identifier}" and certificate leaf = H"{fingerprint.upper()}"'


def sign(bundle):
    bundle = Path(bundle)
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        identifier = plistlib.load(stream)['CFBundleIdentifier']
    explicit = os.environ.get('SIGNING_IDENTITY')
    mode = 'developerCertificate' if explicit else 'localCertificate' if CONFIG.exists() else 'adhoc'
    info_path = bundle / 'Contents/Info.plist'
    with info_path.open('rb') as stream:
        info = plistlib.load(stream)
    info['KeyglowSigningMode'] = mode
    info_path.write_bytes(plistlib.dumps(info))
    # Sign nested public USB components before sealing the enclosing bundle.
    nested_identity = explicit or (json.loads(CONFIG.read_text())['certificateSHA1'] if CONFIG.exists() else '-')
    for nested in [bundle / 'Contents/Helpers/dfu-util']:
        if nested.exists():
            args = ['codesign', '--force', '--sign', nested_identity]
            if nested_identity != '-':
                args += ['--options', 'runtime', '--timestamp' if explicit else '--timestamp=none']
            run(*args, str(nested))
    if explicit:
        run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', explicit, str(bundle))
    elif CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        fingerprint = config['certificateSHA1']
        expected = local_requirement(identifier, fingerprint)
        run('codesign', '--force', '--options', 'runtime', '--timestamp=none', '--sign', fingerprint,
            '--requirements', '=designated => ' + expected, str(bundle))
        run('codesign', '--verify', '--strict', '-R', '=' + expected, str(bundle))
    else:
        run('codesign', '--force', '--sign', '-', str(bundle))
    run('codesign', '--verify', '--strict', str(bundle))


def verify_update(previous, candidate):
    previous = Path(previous)
    if not previous.exists():
        return
    expected = requirement(previous)
    # The one-time migration from a build-specific ad-hoc identity is explicit
    # in setup-local-signing. Once certificate-signed, never silently downgrade.
    if expected.startswith('cdhash '):
        return
    run('codesign', '--verify', '--strict', '-R', '=' + expected, str(candidate))


def require_closed(bundle):
    bundle = Path(bundle)
    if not bundle.exists():
        return
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        executable = plistlib.load(stream)['CFBundleExecutable']
    binary = str((bundle / 'Contents/MacOS' / executable).resolve())
    processes = subprocess.run(['/bin/ps', '-axo', 'comm='], check=True, capture_output=True, text=True)
    if binary in {line.strip() for line in processes.stdout.splitlines()}:
        raise SystemExit('Close Keyglow before replacing the application. The existing bundle was preserved.')


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--verify-update':
        require_closed(sys.argv[2])
        verify_update(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2:
        sign(sys.argv[1])
    else:
        raise SystemExit('Usage: sign-app.py BUNDLE | --verify-update PREVIOUS CANDIDATE')
