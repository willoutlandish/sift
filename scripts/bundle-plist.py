#!/usr/bin/env python3
"""Keep all development settings in the development identity's plist only."""
import plistlib
import os
import re
import sys
from pathlib import Path

def build(development, version=None):
    result = plistlib.loads(Path('Support/Info.plist').read_bytes())
    public_key = os.environ.get('SPARKLE_ED_PUBLIC_KEY')
    if public_key:
        result['SUPublicEDKey'] = public_key
    if version:
        if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
            raise ValueError('VERSION must be x.y.z')
        result['CFBundleShortVersionString'] = version
        result['CFBundleVersion'] = version
    if development:
        result.update(plistlib.loads(Path('Support/Dev.plist').read_bytes()))
        for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable'):
            result[key] = 'Ollie Dev'
        result['CFBundleIdentifier'] = 'com.outlandish.ollie.dev'
        result['CFBundleURLTypes'][0]['CFBundleURLName'] = result['CFBundleIdentifier']
        result['CFBundleURLTypes'][0]['CFBundleURLSchemes'] = ['ollie-dev']
    return result

if __name__ == '__main__':
    Path(sys.argv[2]).write_bytes(plistlib.dumps(build(sys.argv[1] == 'dev', sys.argv[3] if len(sys.argv) > 3 else None), sort_keys=False))
