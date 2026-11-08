#!/usr/bin/env python3
"""Build and sign local release artifacts. Never uploads or accesses the Keychain."""
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

KEY_ENV = 'SPARKLE_ED_PRIVATE_KEY'
KEY_FILE_ENV = 'SPARKLE_ED_PRIVATE_KEY_FILE'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def release(version):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('VERSION must be x.y.z, for example make release-internal VERSION=0.1.0')
    # Strip the secret from all child environments; only sign_update receives a private 0600 temporary file.
    key = os.environ.pop(KEY_ENV, None)
    key_file = os.environ.pop(KEY_FILE_ENV, None)
    if key is not None and key_file:
        raise ValueError(f'Set only one of {KEY_FILE_ENV} and {KEY_ENV}')
    if key is not None:
        try:
            if len(base64.b64decode(key.strip(), validate=True)) not in (32, 64):
                raise ValueError()
        except ValueError:
            raise ValueError(f'{KEY_ENV} must contain a valid Sparkle private key (base64)') from None
    run(['make', 'check-release', f'VERSION={version}'])
    app = Path('dist/Ollie.app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleVersion'] != version or info['CFBundleShortVersionString'] != version:
        raise ValueError('Release version fields do not match VERSION')
    public = info.get('SUPublicEDKey', '')
    bins = Path('.build/artifacts/sparkle/Sparkle/bin')
    output = Path('dist/release')
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / f'Ollie-{version}.dmg'
    appcast = output / 'appcast.xml'
    appcast.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix='ollie-release-', dir=output) as staging:
        shutil.copytree(app, Path(staging) / 'Ollie.app', symlinks=True)
        (Path(staging) / 'Applications').symlink_to('/Applications')
        run(['hdiutil', 'create', '-volname', 'Ollie', '-srcfolder', staging, '-ov', '-format', 'UDZO', str(dmg)])
    if key is None and not key_file:
        raise ValueError(f'No signing key: set {KEY_FILE_ENV} or {KEY_ENV}. The DMG was built; no appcast was created. Keychain is never used.')
    if key_file and not Path(key_file).is_file():
        raise ValueError(f'{KEY_FILE_ENV} must name an existing private-key file')
    temporary_key = None
    try:
        if key is not None:
            descriptor, temporary_key = tempfile.mkstemp(prefix='ollie-sparkle-key-')
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                stream.write(key.strip())
            key_file = temporary_key
        arguments = [str(bins / 'sign_update'), '--ed-key-file', key_file, '-p', str(dmg)]
        signed = subprocess.run(arguments, capture_output=True, text=True)
    finally:
        if temporary_key:
            Path(temporary_key).unlink(missing_ok=True)
    # Never forward signing-tool diagnostics: a malformed secret must not reach logs.
    if signed.returncode:
        raise ValueError('Sparkle signing failed. Check the private-key file or CI signing secret. No unsigned appcast was created.')
    signature = signed.stdout.strip()
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Sparkle did not return a valid EdDSA signature')
    run(['swift', 'scripts/verify-update.swift', str(dmg), signature, public])
    ET.register_namespace('sparkle', SPARKLE)
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Ollie updates'
    ET.SubElement(channel, 'link').text = info['SUFeedURL']
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Ollie {version}'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://outlandishdigital.us/ollie/download/mac/{version}',
        'length': str(dmg.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}version': version, f'{{{SPARKLE}}}shortVersionString': version,
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(root)
    temporary = appcast.with_suffix('.xml.tmp')
    ET.ElementTree(root).write(temporary, encoding='utf-8', xml_declaration=True)
    temporary.replace(appcast)
    architectures = run(['lipo', '-archs', str(app / 'Contents/MacOS/Ollie')], capture_output=True, text=True).stdout.strip()
    print(json.dumps({'dmg': str(dmg.resolve()), 'dmg_bytes': dmg.stat().st_size,
        'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest(),
        'appcast': str(appcast.resolve()), 'appcast_bytes': appcast.stat().st_size,
        'architectures': architectures, 'release_tag': f'ollie-v{version}'}, indent=2))


if __name__ == '__main__':
    try:
        release(sys.argv[1] if len(sys.argv) > 1 else '')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Exceptions from signing are deliberately replaced above with safe messages.
        print(f'Release failed: {error}', file=sys.stderr)
        sys.exit(1)
