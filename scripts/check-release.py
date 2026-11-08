#!/usr/bin/env python3
"""Fail closed on development hosts, test credentials, and assigned secret/token values.
Reports only the filename and pattern name, never the matched value.
"""
import plistlib
import re
import sys
from pathlib import Path

PATTERNS = {
    'development host': rb'(?<![0-9.])100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?![0-9.])',
    'test credential': b'e2e-local-test-secret',
    'assigned credential': rb'''(?i)(?:app[_-]?secret|access[_-]?token|refresh[_-]?token|tenant[_-]?access[_-]?token)["'\s]*[:=]["'\s]*[A-Za-z0-9_+/=-]{16,}''',
    'Lark token': rb'(?<![A-Za-z0-9])[ut]-[A-Za-z0-9_-]{32,}',
    'JWT': rb'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}',
}

def check(bundle):
    errors = []
    try:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'com.outlandish.ollie':
            errors.append('wrong release identity')
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
        for name, pattern in PATTERNS.items():
            if re.search(pattern, data):
                errors.append(f'{file.relative_to(bundle)}: {name}')
    return errors

if __name__ == '__main__':
    failures = check(Path(sys.argv[1]))
    for failure in failures:
        print(f'FAIL: {failure}', file=sys.stderr)
    if not failures:
        print('Release identity and secret scan passed')
    sys.exit(bool(failures))
