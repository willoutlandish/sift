#!/usr/bin/env python3
"""Exercise fail-closed packaging paths without accessing a signing key."""
import importlib.util
import base64
import stat
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_internal', Path(__file__).with_name('release-internal.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original = Path.cwd()
        os.chdir(self.temporary.name)
        contents = Path('dist/Ollie.app/Contents')
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleVersion': '0.1.0', 'CFBundleShortVersionString': '0.1.0',
            'SUPublicEDKey': 'public-key',
        }))
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        os.chdir(self.original)
        self.temporary.cleanup()

    def test_missing_key_fails_without_appcast(self):
        with patch.object(release, 'run'), patch.object(release.subprocess, 'run'):
            with self.assertRaisesRegex(ValueError, 'No signing key'):
                release.release('0.1.0')
        self.assertFalse(Path('dist/release/appcast.xml').exists())

    def test_missing_file_never_invokes_signer(self):
        os.environ[release.KEY_FILE_ENV] = '/does-not-exist'
        with patch.object(release, 'run'), patch.object(release.subprocess, 'run') as signer:
            with self.assertRaisesRegex(ValueError, 'existing private-key file'):
                release.release('0.1.0')
            signer.assert_not_called()
        self.assertFalse(Path('dist/release/appcast.xml').exists())

    def test_ambiguous_signing_configuration_fails(self):
        os.environ[release.KEY_ENV] = 'fixture'
        os.environ[release.KEY_FILE_ENV] = 'fixture'
        with self.assertRaisesRegex(ValueError, 'only one'):
            release.release('0.1.0')

    def test_environment_key_uses_private_file_and_is_removed_on_signer_failure(self):
        seed = base64.b64encode(bytes(32)).decode()
        os.environ[release.KEY_ENV] = seed
        captured = []
        def signer(args, **kwargs):
            path = Path(args[args.index('--ed-key-file') + 1])
            captured.append(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.read_text(), seed)
            self.assertNotIn(release.KEY_ENV, os.environ)
            self.assertNotIn(seed, args)
            return CompletedProcess(args, 1, '', 'untrusted diagnostic')
        with patch.object(release, 'run'), patch.object(release.subprocess, 'run', side_effect=signer):
            with self.assertRaisesRegex(ValueError, 'Sparkle signing failed'):
                release.release('0.1.0')
        self.assertEqual(len(captured), 1)
        self.assertFalse(captured[0].exists())
        self.assertFalse(Path('dist/release/appcast.xml').exists())

    def test_invalid_version_never_builds(self):
        with patch.object(release, 'run') as build:
            for version in ['', '1.0', '../1.0.0', '01.0.0', '1.0.0;echo bad']:
                with self.assertRaisesRegex(ValueError, 'VERSION'):
                    release.release(version)
            build.assert_not_called()

    def test_invalid_ci_secret_is_not_echoed(self):
        secret = 'fixture-value-must-not-appear'
        os.environ[release.KEY_ENV] = secret
        with self.assertRaises(ValueError) as raised:
            release.release('0.1.0')
        self.assertNotIn(secret, str(raised.exception))
        self.assertNotIn(release.KEY_ENV, os.environ)


if __name__ == '__main__':
    unittest.main()
