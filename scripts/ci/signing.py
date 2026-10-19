#!/usr/bin/env python3
"""Import existing CI signing assets; never create or fetch Apple identities."""
import base64
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # security stderr can include identity information. Keep CI errors redacted.
        raise RuntimeError(f'{Path(args[0]).name} signing command failed (exit {result.returncode}).')
    return result.stdout.strip()


def validate_profile(profile, bundle, team):
    if profile.get('TeamIdentifier') != [team]:
        raise ValueError('Provisioning profile team mismatch.')
    entitlements = profile.get('Entitlements', {})
    identifier = entitlements.get('application-identifier', '')
    prefix, separator, profile_bundle = identifier.partition('.')
    if not separator or not re.fullmatch(r'[A-Z0-9]{10}', prefix) or profile_bundle != bundle:
        raise ValueError('Provisioning profile bundle mismatch or wildcard.')
    if entitlements.get('get-task-allow') is not False or profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
        raise ValueError('An existing App Store distribution provisioning profile is required.')
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile is expired or missing expiry.')
    if not re.fullmatch(r'[0-9A-Fa-f-]{36}', profile.get('UUID', '')):
        raise ValueError('Invalid provisioning profile UUID.')
    name = profile.get('Name', '')
    if not name.strip() or '\n' in name or '\r' in name:
        raise ValueError('Invalid provisioning profile name.')
    return name


def paths():
    runner = Path(os.environ['RUNNER_TEMP']).resolve()
    return runner / 'ammo-signing', runner / 'ammo-signing-state.json'


def save_state(path, state):
    path.write_text(json.dumps(state))
    path.chmod(0o600)


def cleanup():
    private, state_path = paths()
    errors = []
    try:
        if state_path.exists():
            state = {}
            try:
                state = json.loads(state_path.read_text())
                if not isinstance(state, dict):
                    raise ValueError('Invalid signing cleanup state.')
            except Exception as error:
                errors.append(error)
                state = {}
            if state.get('originalKeychains'):
                try:
                    command('security', 'list-keychains', '-d', 'user', '-s', *state['originalKeychains'])
                except Exception as error:
                    errors.append(error)
            if state.get('keychain') and Path(state['keychain']).exists():
                try:
                    command('security', 'delete-keychain', state['keychain'])
                except Exception as error:
                    errors.append(error)
            for profile in state.get('profiles', []):
                try:
                    Path(profile).unlink(missing_ok=True)
                except Exception as error:
                    errors.append(error)
            try:
                state_path.unlink()
            except Exception as error:
                errors.append(error)
    except Exception as error:
        errors.append(error)
    finally:
        shutil.rmtree(private, ignore_errors=True)
    if errors or private.exists():
        raise RuntimeError('Temporary signing cleanup encountered an error; the ephemeral runner must be discarded.')


def prepare():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise RuntimeError('Signing import is limited to the ephemeral GitHub runner.')
    required = ['APPLE_TEAM_ID', 'IOS_BUNDLE_ID', 'IOS_DISTRIBUTION_CERTIFICATE_BASE64',
                'IOS_DISTRIBUTION_CERTIFICATE_PASSWORD', 'IOS_APP_PROFILE_BASE64',
                'IOS_WIDGET_PROFILE_BASE64', 'ASC_API_KEY_ID', 'ASC_API_KEY_P8_B64']
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        raise RuntimeError('Missing CI settings: ' + ', '.join(missing))
    if not re.fullmatch(r'[A-Z0-9]{10}', os.environ['APPLE_TEAM_ID']) or not re.fullmatch(r'[A-Z0-9]+', os.environ['ASC_API_KEY_ID']):
        raise ValueError('Invalid Apple team or API key identifier format.')
    private, state_path = paths()
    private.mkdir(mode=0o700, exist_ok=False)
    keychain = private / 'signing.keychain-db'
    state = {'keychain': str(keychain), 'profiles': [],
             'originalKeychains': shlex.split(command('security', 'list-keychains', '-d', 'user'))}
    save_state(state_path, state)
    try:
        def decode(name, destination):
            destination.write_bytes(base64.b64decode(os.environ[name], validate=True))
            destination.chmod(0o600)
        certificate = private / 'distribution.p12'
        decode('IOS_DISTRIBUTION_CERTIFICATE_BASE64', certificate)
        keypath = private / ('AuthKey_' + os.environ['ASC_API_KEY_ID'] + '.p8')
        decode('ASC_API_KEY_P8_B64', keypath)
        password = secrets.token_urlsafe(32)
        command('security', 'create-keychain', '-p', password, str(keychain))
        command('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
        command('security', 'unlock-keychain', '-p', password, str(keychain))
        command('security', 'import', str(certificate), '-k', str(keychain), '-P', os.environ['IOS_DISTRIBUTION_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
        command('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain))
        command('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *state['originalKeychains'])
        certificate.unlink()
        profiles = {}
        profile_directory = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
        profile_directory.mkdir(parents=True, exist_ok=True)
        for kind, suffix in [('APP', ''), ('WIDGET', '.widgets')]:
            source = private / (kind + '.mobileprovision')
            decode('IOS_' + kind + '_PROFILE_BASE64', source)
            profile = plistlib.loads(command('security', 'cms', '-D', '-i', str(source)).encode())
            bundle = os.environ['IOS_BUNDLE_ID'] + suffix
            profiles[bundle] = validate_profile(profile, bundle, os.environ['APPLE_TEAM_ID'])
            destination = profile_directory / (profile['UUID'] + '.mobileprovision')
            if destination.exists():
                raise RuntimeError('Refusing to overwrite an existing provisioning profile.')
            # Record before writing so interrupted import is still cleaned up.
            state['profiles'].append(str(destination))
            save_state(state_path, state)
            shutil.copyfile(source, destination)
            destination.chmod(0o600)
        # --project-root . makes includes relative to the repository root.
        overlay = {'include': ['project.yml'], 'targets': {}}
        for target, suffix in [('AmmoPhone', ''), ('AmmoWidgets', '.widgets')]:
            overlay['targets'][target] = {'settings': {'configs': {'Release': {
                'CODE_SIGN_STYLE': 'Manual', 'CODE_SIGN_IDENTITY': 'Apple Distribution',
                'PROVISIONING_PROFILE_SPECIFIER': profiles[os.environ['IOS_BUNDLE_ID'] + suffix],
            }}}}
        (ROOT / '.build').mkdir(exist_ok=True)
        (ROOT / '.build/ci-signing.json').write_text(json.dumps(overlay))
        with open(os.environ['GITHUB_ENV'], 'a') as output:
            for name, value in {'ASC_API_KEY_PATH': str(keypath), 'API_PRIVATE_KEYS_DIR': str(private),
                                'IOS_SIGNING_STYLE': 'manual', 'IOS_PROVISIONING_PROFILES': json.dumps(profiles)}.items():
                output.write(name + '=' + value + '\n')
        print('Imported existing distribution identity and validated app/widget profiles into a temporary keychain.')
    except Exception:
        cleanup()
        raise


if __name__ == '__main__':
    try:
        {'prepare': prepare, 'cleanup': cleanup}[sys.argv[1]]()
    except Exception as error:
        print('Signing setup blocked: ' + str(error), file=sys.stderr)
        sys.exit(1)
