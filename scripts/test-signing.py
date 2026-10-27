#!/usr/bin/env python3
"""Offline signature checks; never launches an app or accesses a keyboard."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('sign_app', Path(__file__).with_name('sign-app.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def verify(bundle, requirement, expected=True):
    result = subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(bundle)], capture_output=True)
    assert (result.returncode == 0) == expected, 'Unexpected signature requirement result'


def main():
    # This suite tests the local certificate specifically, even when a shell
    # normally builds releases with a Developer ID override.
    os.environ.pop('SIGNING_IDENTITY', None)
    if not signing.CONFIG.exists():
        raise SystemExit('Configure local signing first; this test creates no credentials.')
    config = json.loads(signing.CONFIG.read_text())
    identifier = 'local.keyglow.signing-fixture'
    with tempfile.TemporaryDirectory(prefix='keyglow-signing-test-') as temporary:
        folder = Path(temporary)
        bundles = []
        for index in range(4):
            bundle = folder / f'Fixture{index}.app'
            (bundle / 'Contents/MacOS').mkdir(parents=True)
            info = {'CFBundleIdentifier': identifier if index != 2 else identifier+'.other',
                    'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL'}
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(bundle/'Contents/MacOS/Fixture')],
                           input=f'int main(void) {{ return {index}; }}\n', text=True, check=True)
            if index == 3:
                subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
            else:
                signing.sign(bundle)
            bundles.append(bundle)
        a, b, other, adhoc = bundles
        expected = signing.requirement(a)
        assert expected == signing.requirement(b) and 'cdhash' not in expected
        verify(a, signing.local_requirement(identifier, config['certificateSHA1']))
        verify(b, signing.local_requirement(identifier, config['certificateSHA1']))
        assert (a/'Contents/MacOS/Fixture').read_bytes() != (b/'Contents/MacOS/Fixture').read_bytes()
        verify(a, signing.requirement(b)); verify(b, expected)
        signing.verify_update(a, b)
        verify(other, expected, False); verify(adhoc, expected, False)
        fingerprint = config['certificateSHA1']
        wrong = ('0' if fingerprint[0] != '0' else '1') + fingerprint[1:]
        verify(a, signing.local_requirement(identifier, wrong), False)
        print('Stable signing passed: distinct builds, reciprocal requirements, wrong ID/certificate and ad-hoc rejection. No app launched.')


if __name__ == '__main__':
    main()
