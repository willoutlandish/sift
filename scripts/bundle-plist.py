#!/usr/bin/env python3
"""Keep all development settings in the development identity's plist only."""
import argparse
import plistlib
import os
import re
import sys
from pathlib import Path
from release_policy import PUBLIC_KEY, FEED_URL, THROWAWAY_ID, require_throwaway_output

def build(development, version=None, throwaway=False):
    result = plistlib.loads(Path('Support/Info.plist').read_bytes())
    public_key = os.environ.get('SPARKLE_ED_PUBLIC_KEY')
    result['SUPublicEDKey'] = PUBLIC_KEY
    result['SUFeedURL'] = FEED_URL
    if public_key and (development or throwaway):
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
    if throwaway:
        result['CFBundleIdentifier'] = THROWAWAY_ID
        result['CFBundleDisplayName'] = 'Ollie Throwaway - DO NOT DISTRIBUTE'
        result['CFBundleURLTypes'][0]['CFBundleURLName'] = THROWAWAY_ID
        result['CFBundleURLTypes'][0]['CFBundleURLSchemes'] = ['ollie-throwaway']
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('identity', choices=['dev', 'release'])
    parser.add_argument('output', type=Path)
    parser.add_argument('version', nargs='?', default=None)
    parser.add_argument('--throwaway', action='store_true')
    args = parser.parse_args()
    if args.throwaway:
        require_throwaway_output(args.output)
    args.output.write_bytes(plistlib.dumps(build(args.identity == 'dev', args.version, args.throwaway), sort_keys=False))
