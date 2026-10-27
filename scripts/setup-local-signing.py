#!/usr/bin/env python3
"""Explicit one-time creation of a private local code-signing identity.

The private key is imported non-extractable into the login Keychain with access
limited to /usr/bin/codesign. No trust, TCC, or Gatekeeper settings are changed.
Only a public certificate fingerprint is retained in the configuration file.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

NAME = 'Keyglow Local Development'
CONFIG = Path.home() / 'Library/Application Support/Keyglow/Development/signing.json'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--create', action='store_true', help='Create the persistent signing credential explicitly')
    args = parser.parse_args()
    if CONFIG.exists():
        print('Local signing is configured:', CONFIG)
        return
    if not args.create:
        print('No local signing identity configured. Use --create once to provision it.')
        return
    # Refuse to generate a second similarly named key if configuration was lost.
    existing = subprocess.run(['security', 'find-certificate', '-c', NAME], capture_output=True)
    if existing.returncode == 0:
        raise SystemExit('A Keyglow signing certificate already exists. Recover its configuration; do not create another key.')
    keychain = run(['security', 'default-keychain', '-d', 'user'], capture_output=True, text=True).stdout.strip().strip('"')
    if not keychain:
        raise SystemExit('No user default Keychain available')
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='keyglow-signing-') as temporary:
        folder = Path(temporary)
        config = folder / 'openssl.cnf'
        config.write_text('''[req]
distinguished_name=subject
x509_extensions=code_signing
prompt=no
[subject]
CN=Keyglow Local Development
[code_signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
''')
        key, cert, p12 = [folder / name for name in ('key.pem', 'certificate.pem', 'identity.p12')]
        run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256', '-days', '3650',
             '-config', str(config), '-keyout', str(key), '-out', str(cert)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        result = run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-noout', '-fingerprint', '-sha1'], capture_output=True, text=True)
        fingerprint = result.stdout.strip().split('=', 1)[1].replace(':', '').upper()
        if not re.fullmatch(r'[A-F0-9]{40}', fingerprint):
            raise SystemExit('Invalid generated certificate fingerprint')
        # Use the macOS-compatible PKCS#12 encoding and a disposable wrapping
        # password. It is unrelated to the user's password and is never logged.
        wrapping = secrets.token_urlsafe(32)
        run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(cert),
             '-name', NAME, '-out', str(p12), '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES',
             '-macalg', 'sha1', '-passout', 'stdin'], input=wrapping+'\n', text=True,
             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        imported = subprocess.run(['security', 'import', str(p12), '-k', keychain, '-f', 'pkcs12',
                                   '-P', wrapping, '-x', '-T', '/usr/bin/codesign'], capture_output=True, text=True)
        if imported.returncode:
            # CalledProcessError would include the disposable password in argv.
            raise SystemExit('Keychain import did not complete: '+imported.stderr.strip())
        CONFIG.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        CONFIG.write_text(json.dumps({'version': 1, 'name': NAME, 'certificateSHA1': fingerprint}, indent=2) + '\n')
        CONFIG.chmod(0o600)
    print('Local identity created in the user Keychain. Public configuration:', CONFIG)
    print('The existing ad-hoc macOS grant may need one migration. Future builds must pass the previous identity requirement.')


if __name__ == '__main__':
    main()
