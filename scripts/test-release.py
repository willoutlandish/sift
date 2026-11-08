#!/usr/bin/env python3
"""Exercise fail-closed packaging paths without accessing a signing key."""
import importlib.util
import base64
import stat
import signal
import subprocess
import sys
import selectors
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_internal', Path(__file__).with_name('release-internal.py'))
REPO = Path(__file__).resolve().parent.parent
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

bundle = module('bundle-plist.py', 'bundle_plist')
scan = module('check-release.py', 'check_release')
from release_policy import PUBLIC_KEY, FEED_URL, THROWAWAY_ID


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


    def test_critical_and_minimum_options_are_version_paired(self):
        tree = release.appcast_tree('0.1.1', FEED_URL, 123, 'signature', True, '0.1.0')
        item = tree.find('channel/item')
        self.assertIsNotNone(item.find(f'{{{release.SPARKLE}}}criticalUpdate'))
        self.assertEqual(item.find(f'{{{release.SPARKLE}}}minimumAutoupdateVersion').text, '0.1.0')
        self.assertEqual(item.find('enclosure').get(f'{{{release.SPARKLE}}}version'), '0.1.1')
        ordinary = release.appcast_tree('0.1.1', FEED_URL, 123, 'signature').find('channel/item')
        self.assertIsNone(ordinary.find(f'{{{release.SPARKLE}}}criticalUpdate'))
        with patch.object(release, 'run') as build:
            for critical, minimum in [('yes', ''), ('1', '0.2.0'), ('1', 'garbage')]:
                with self.assertRaises(ValueError):
                    release.release('0.1.1', critical=critical, minimum_version=minimum)
            build.assert_not_called()

    def test_signal_cleanup_of_private_temporary_file(self):
        code = """
import base64, importlib.util, signal, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location('release', sys.argv[1] + '/release-internal.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
with r.signing_key_file(base64.b64encode(bytes(32)).decode(), None) as path:
    print(path, flush=True)
    signal.pause()
"""
        for number in (signal.SIGTERM, signal.SIGINT):
            child = subprocess.Popen([sys.executable, '-c', code, str(REPO / 'scripts')], stdout=subprocess.PIPE, text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(timeout=5), 'private file setup timed out')
                path = Path(child.stdout.readline().strip())
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                child.send_signal(number)
                self.assertEqual(child.wait(timeout=5), 128 + number)
                self.assertFalse(path.exists())
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
                child.stdout.close()


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original = Path.cwd()
        os.chdir(self.temporary.name)
        Path('Support').mkdir()
        for name in ('Info.plist', 'Dev.plist'):
            Path('Support', name).write_bytes((REPO / 'Support' / name).read_bytes())
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        os.chdir(self.original)
        self.temporary.cleanup()

    def app(self, info, path='dist/Ollie.app'):
        app = Path(path)
        (app / 'Contents').mkdir(parents=True, exist_ok=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app

    def test_stray_public_environment_cannot_change_release(self):
        os.environ['SPARKLE_ED_PUBLIC_KEY'] = base64.b64encode(bytes(32)).decode()
        info = bundle.build(False, '0.1.0')
        self.assertEqual(info['SUPublicEDKey'], PUBLIC_KEY)
        self.assertEqual(info['SUFeedURL'], FEED_URL)
        self.assertEqual(scan.check(self.app(info)), [])

    def test_release_scan_rejects_wrong_key_and_feed(self):
        info = bundle.build(False)
        for field, message in [('SUPublicEDKey', 'public key'), ('SUFeedURL', 'feed')]:
            invalid = {**info, field: 'wrong-value'}
            self.assertTrue(any(message in failure for failure in scan.check(self.app(invalid))))

    def test_throwaway_flag_is_separate_identity_and_folder(self):
        os.environ['SPARKLE_ED_PUBLIC_KEY'] = base64.b64encode(bytes(32)).decode()
        info = bundle.build(False, '0.1.0', throwaway=True)
        self.assertEqual(info['CFBundleIdentifier'], THROWAWAY_ID)
        self.assertNotEqual(info['SUPublicEDKey'], PUBLIC_KEY)
        app = self.app(info, 'dist/throwaway-release/Ollie.app')
        self.assertEqual(scan.check(app, throwaway=True), [])
        self.assertTrue(scan.check(app))
        self.assertTrue(scan.check(self.app(info), throwaway=True))
        # Even an explicit throwaway scan must reject a real identity with a test key.
        info['CFBundleIdentifier'] = 'com.outlandish.ollie'
        self.assertTrue(any('production update public key' in error for error in scan.check(self.app(info, str(app)), throwaway=True)))
        out = Path('dist/Ollie.app/Contents/Info.plist')
        previous = out.read_bytes()
        result = subprocess.run([sys.executable, str(REPO / 'scripts/bundle-plist.py'), 'release', str(out), '0.1.0', '--throwaway'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(out.read_bytes(), previous)

    def test_known_secret_values_are_rejected_without_echoing(self):
        app = self.app(bundle.build(False))
        for name in ['LARK_APP_SECRET', 'LARK_ACCESS_TOKEN', 'OTHER_PASSWORD']:
            secret = 'random-value-with-no-credential-marker'
            with patch.dict(os.environ, {name: secret}):
                (app / 'Contents/opaque').write_text(secret)
                errors = scan.check(app)
                self.assertTrue(any('known secret value' in error for error in errors))
                self.assertNotIn(secret, str(errors))



if __name__ == '__main__':
    unittest.main()
