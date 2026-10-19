import datetime
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from signing import cleanup, prepare, validate_profile


class ProvisioningValidation(unittest.TestCase):
    def profile(self):
        return {'TeamIdentifier': ['ABCDEFGHIJ'], 'Name': 'Synthetic App Store Profile',
                'UUID': '12345678-1234-1234-1234-123456789abc',
                'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
                'Entitlements': {'application-identifier': 'ABCDEFGHIJ.org.example.ammo', 'get-task-allow': False}}

    def test_existing_exact_distribution_profile(self):
        self.assertEqual(validate_profile(self.profile(), 'org.example.ammo', 'ABCDEFGHIJ'), 'Synthetic App Store Profile')

    def test_bundle_match_is_exact_but_legacy_app_prefix_may_differ_from_team(self):
        profile = self.profile()
        profile['Entitlements']['application-identifier'] = 'OLDPREFIX1.org.example.ammo'
        self.assertEqual(validate_profile(profile, 'org.example.ammo', 'ABCDEFGHIJ'), profile['Name'])
        for identifier in ['ABCDEFGHIJ.other.org.example.ammo', 'INVALID.org.example.ammo',
                           'ABCDEFGHIJ.org.example.ammo.extra']:
            profile['Entitlements']['application-identifier'] = identifier
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                validate_profile(profile, 'org.example.ammo', 'ABCDEFGHIJ')

    def test_import_rejects_non_hosted_runner_before_touching_signing_state(self):
        with patch.dict('os.environ', {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'}, clear=True), \
             patch('signing.paths') as paths, patch('signing.command') as command:
            with self.assertRaisesRegex(RuntimeError, 'ephemeral GitHub runner'):
                prepare()
            paths.assert_not_called()
            command.assert_not_called()

    def test_reject_wrong_team_bundle_expired_and_non_store_profiles(self):
        for patch in [{'TeamIdentifier': ['OTHERTEAM1']}, {'ProvisionedDevices': ['device']},
                      {'ProvisionsAllDevices': True}, {'ExpirationDate': datetime.datetime(2020, 1, 1)},
                      {'Entitlements': {'application-identifier': 'ABCDEFGHIJ.*', 'get-task-allow': False}},
                      {'Entitlements': {'application-identifier': 'ABCDEFGHIJ.org.example.ammo', 'get-task-allow': True}},
                      {'Name': 'bad\nprofile'}]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                validate_profile({**self.profile(), **patch}, 'org.example.ammo', 'ABCDEFGHIJ')

    def test_cleanup_removes_files_even_when_keychain_commands_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / 'private'
            private.mkdir()
            keychain = private / 'synthetic.keychain-db'
            keychain.write_text('synthetic test fixture')
            (private / 'synthetic.p8').write_text('synthetic test fixture')
            profile = root / 'synthetic.mobileprovision'
            profile.write_text('synthetic test fixture')
            state = root / 'state.json'
            state.write_text(json.dumps({'keychain': str(keychain), 'profiles': [str(profile)], 'originalKeychains': ['synthetic-original']}))
            with patch('signing.paths', return_value=(private, state)), patch('signing.command', side_effect=RuntimeError('synthetic keychain failure')):
                with self.assertRaisesRegex(RuntimeError, 'cleanup encountered an error'):
                    cleanup()
            self.assertFalse(private.exists())
            self.assertFalse(profile.exists())
            self.assertFalse(state.exists())

    def test_cleanup_removes_private_files_when_state_json_is_incomplete(self):
        for content in ['{"keychain":', 'null', '{"profiles": null}']:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                private = root / 'private'
                private.mkdir()
                (private / 'synthetic.p8').write_text('synthetic test fixture')
                state = root / 'state.json'
                state.write_text(content)
                with patch('signing.paths', return_value=(private, state)), patch('signing.command') as command:
                    with self.assertRaisesRegex(RuntimeError, 'cleanup encountered an error'):
                        cleanup()
                    command.assert_not_called()
                self.assertFalse(private.exists())

    def test_cleanup_removes_private_files_when_state_unlink_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / 'private'
            private.mkdir()
            (private / 'synthetic.p8').write_text('synthetic test fixture')
            state = root / 'state.json'
            state.write_text('{}')
            original_unlink = Path.unlink
            def unlink(path, *args, **kwargs):
                if path == state:
                    raise PermissionError('synthetic state unlink failure')
                return original_unlink(path, *args, **kwargs)
            with patch('signing.paths', return_value=(private, state)), patch.object(Path, 'unlink', unlink):
                with self.assertRaisesRegex(RuntimeError, 'cleanup encountered an error'):
                    cleanup()
            self.assertFalse(private.exists())
            self.assertTrue(state.exists())


if __name__ == '__main__':
    unittest.main()
