#!/usr/bin/env python3
"""Build and sign local release artifacts. Never uploads or accesses the Keychain."""
import argparse
import atexit
import signal
from contextlib import contextmanager
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
from release_policy import THROWAWAY_ROOT

KEY_ENV = 'SPARKLE_ED_PRIVATE_KEY'
KEY_FILE_ENV = 'SPARKLE_ED_PRIVATE_KEY_FILE'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def validate_version(version, name='VERSION'):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError(f'{name} must be x.y.z')
    return tuple(map(int, version.split('.')))


@contextmanager
def signing_key_file(seed, existing):
    if seed is None:
        yield existing
        return
    path = None
    def cleanup():
        if path:
            Path(path).unlink(missing_ok=True)
    def interrupted(number, frame):
        cleanup()
        raise SystemExit(128 + number)
    previous = {number: signal.signal(number, interrupted) for number in (signal.SIGTERM, signal.SIGINT)}
    atexit.register(cleanup)
    try:
        descriptor, path = tempfile.mkstemp(prefix='ollie-sparkle-key-')
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(seed.strip())
        yield path
    finally:
        cleanup()
        atexit.unregister(cleanup)
        for number, handler in previous.items():
            signal.signal(number, handler)


def appcast_tree(version, feed, size, signature, critical=False, minimum_version=''):
    ET.register_namespace('sparkle', SPARKLE)
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Ollie updates'
    ET.SubElement(channel, 'link').text = feed
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Ollie {version}'
    if critical:
        ET.SubElement(item, f'{{{SPARKLE}}}criticalUpdate')
    if minimum_version:
        ET.SubElement(item, f'{{{SPARKLE}}}minimumAutoupdateVersion').text = minimum_version
    ET.SubElement(item, 'enclosure', {
        'url': f'https://outlandishdigital.us/ollie/download/mac/{version}',
        'length': str(size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}version': version, f'{{{SPARKLE}}}shortVersionString': version,
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(root)
    return ET.ElementTree(root)


def release(version, throwaway=False, critical='', minimum_version=''):
    version_parts = validate_version(version)
    if critical not in ('', '0', '1'):
        raise ValueError('CRITICAL must be 0 or 1')
    if minimum_version and validate_version(minimum_version, 'MIN_VERSION') > version_parts:
        raise ValueError('MIN_VERSION cannot exceed VERSION')
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
    run(['make', 'check-release', f'VERSION={version}', f'THROWAWAY={int(throwaway)}'])
    app = (THROWAWAY_ROOT if throwaway else Path('dist')) / 'Ollie.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleVersion'] != version or info['CFBundleShortVersionString'] != version:
        raise ValueError('Release version fields do not match VERSION')
    public = info.get('SUPublicEDKey', '')
    bins = Path('.build/artifacts/sparkle/Sparkle/bin')
    output = THROWAWAY_ROOT if throwaway else Path('dist/release')
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
    with signing_key_file(key, key_file) as signing_path:
        arguments = [str(bins / 'sign_update'), '--ed-key-file', signing_path, '-p', str(dmg)]
        signed = subprocess.run(arguments, capture_output=True, text=True)
    # Never forward signing-tool diagnostics: a malformed secret must not reach logs.
    if signed.returncode:
        raise ValueError('Sparkle signing failed. Check the private-key file or CI signing secret. No unsigned appcast was created.')
    signature = signed.stdout.strip()
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Sparkle did not return a valid EdDSA signature')
    run(['swift', 'scripts/verify-update.swift', str(dmg), signature, public])
    tree = appcast_tree(version, info['SUFeedURL'], dmg.stat().st_size, signature,
                        critical == '1', minimum_version)
    temporary = appcast.with_suffix('.xml.tmp')
    tree.write(temporary, encoding='utf-8', xml_declaration=True)
    temporary.replace(appcast)
    architectures = run(['lipo', '-archs', str(app / 'Contents/MacOS/Ollie')], capture_output=True, text=True).stdout.strip()
    print(json.dumps({'dmg': str(dmg.resolve()), 'dmg_bytes': dmg.stat().st_size,
        'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest(),
        'appcast': str(appcast.resolve()), 'appcast_bytes': appcast.stat().st_size,
        'architectures': architectures, 'throwaway': throwaway,
        'release_tag': None if throwaway else f'ollie-v{version}'}, indent=2))


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument('version')
        parser.add_argument('--throwaway', action='store_true')
        parser.add_argument('--critical', default='')
        parser.add_argument('--minimum-version', default='')
        args = parser.parse_args()
        release(args.version, args.throwaway, args.critical, args.minimum_version)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Exceptions from signing are deliberately replaced above with safe messages.
        print(f'Release failed: {error}', file=sys.stderr)
        sys.exit(1)
