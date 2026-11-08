#!/usr/bin/env python3
"""Fail closed on development hosts, test credentials, and assigned secret/token values.
Reports only the filename and pattern name, never the matched value.
"""
import argparse
import base64
import os
import plistlib
import re
import sys
from pathlib import Path
from release_policy import PUBLIC_KEY, FEED_URL, THROWAWAY_ID, require_throwaway_output

PATTERNS = {
    'development host': rb'(?<![0-9.])100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?![0-9.])',
    'test credential': b'e2e-local-test-secret',
    'assigned credential': rb'''(?i)(?:app[_-]?secret|access[_-]?token|refresh[_-]?token|tenant[_-]?access[_-]?token)["'\s]*[:=]["'\s]*[A-Za-z0-9_+/=-]{16,}''',
    'Lark token': rb'(?<![A-Za-z0-9])[ut]-[A-Za-z0-9_-]{32,}',
    'JWT': rb'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}',
}

def check(bundle, throwaway=False):
    errors = []
    if throwaway:
        try:
            require_throwaway_output(bundle)
        except ValueError as error:
            errors.append(str(error))
    secret_values = [value.encode(encoding) for name, value in os.environ.items() for encoding in ('utf-8', 'utf-16-le', 'utf-16-be') if value and
        re.search(r'(?:^|_)(?:SECRET|TOKEN|PASSWORD|PRIVATE_KEY)(?:$|_)', name) and not name.endswith('_FILE')]

    try:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != (THROWAWAY_ID if throwaway else 'com.outlandish.ollie'):
            errors.append('wrong release identity')
        if not throwaway or info.get('CFBundleIdentifier') == 'com.outlandish.ollie':
            if info.get('SUPublicEDKey') != PUBLIC_KEY:
                errors.append('wrong production update public key')
        else:
            try:
                if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32:
                    raise ValueError()
            except ValueError:
                errors.append('invalid throwaway update public key')
        if info.get('SUFeedURL') != FEED_URL:
            errors.append('wrong production update feed')
        if any('dev' in key.lower() and key != 'CFBundleDevelopmentRegion' for key in info):
            errors.append('development plist key')
        if 'NSAppTransportSecurity' in info:
            errors.append('development ATS policy')
        if 'SUPublicDSAKey' in info or 'SUPublicDSAKeyFile' in info:
            errors.append('legacy DSA key')
    except (OSError, ValueError):
        errors.append('missing or invalid release plist')
    for file in bundle.rglob('*'):
        if not file.is_file() or file.is_symlink():
            continue
        data = file.read_bytes()
        if any(value in data for value in secret_values):
            errors.append(f'{file.relative_to(bundle)}: known secret value')
        for name, pattern in PATTERNS.items():
            if re.search(pattern, data):
                errors.append(f'{file.relative_to(bundle)}: {name}')
    return errors

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--throwaway', action='store_true')
    args = parser.parse_args()
    failures = check(args.bundle, args.throwaway)
    for failure in failures:
        print(f'FAIL: {failure}', file=sys.stderr)
    if not failures:
        print('Release identity and secret scan passed')
    sys.exit(bool(failures))
