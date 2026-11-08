"""Pinned production update identity; shared by bundle creation and validation."""
from pathlib import Path

PUBLIC_KEY = 'W4XDx/UA6Xzj5TUDbcQ4sQBzrmwr7/6HYXIyaDtEBlk='
FEED_URL = 'https://outlandishdigital.us/ollie/appcast.xml'
THROWAWAY_ID = 'com.outlandish.ollie.throwaway.dev'
THROWAWAY_ROOT = Path('dist/throwaway-release')


def require_throwaway_output(path):
    if not Path(path).resolve().is_relative_to(THROWAWAY_ROOT.resolve()):
        raise ValueError('Throwaway output must stay under dist/throwaway-release')
