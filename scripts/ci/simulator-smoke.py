#!/usr/bin/env python3
"""Launch the built app in a fresh simulator; record only this limited smoke test."""
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    app = ROOT / '.build/native-ios/Build/Products/Debug-iphonesimulator/AmmoPhone.app'
    bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json'))['runtimes']
    usable = [r for r in runtimes if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
    if not usable:
        raise RuntimeError('No available iOS simulator runtime; smoke evidence cannot be produced.')
    runtime = max(usable, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
    devices = runtime.get('supportedDeviceTypes', [])
    phone = next((d['identifier'] for d in devices if 'iPhone' in d['identifier']), None)
    if not phone:
        raise RuntimeError('Runtime has no supported iPhone device type.')
    simulator = run('xcrun', 'simctl', 'create', 'Ammo CI Smoke', phone, runtime['identifier'])
    output = ROOT / '.build/ci'
    output.mkdir(parents=True, exist_ok=True)
    try:
        run('xcrun', 'simctl', 'boot', simulator)
        run('xcrun', 'simctl', 'bootstatus', simulator, '-b')
        run('xcrun', 'simctl', 'install', simulator, str(app))
        run('xcrun', 'simctl', 'launch', simulator, bundle)
        time.sleep(5)
        # launchctl confirms the launched process is still alive after startup.
        processes = run('xcrun', 'simctl', 'spawn', simulator, 'launchctl', 'list')
        if not any(bundle in line and line.split()[0].isdigit() for line in processes.splitlines()):
            raise RuntimeError('App exited during launch smoke test.')
        screenshot = output / 'ios-simulator-smoke.png'
        run('xcrun', 'simctl', 'io', simulator, 'screenshot', str(screenshot))
        record = {
            'commit': run('git', '-C', str(ROOT), 'rev-parse', 'HEAD'),
            'bundleID': bundle,
            'runtime': runtime['identifier'],
            'launchSucceeded': True,
            'screenshotSha256': hashlib.sha256(screenshot.read_bytes()).hexdigest(),
            'scope': 'Fresh simulator install, launch, five-second process check and screenshot only; no device, APNs, provider, or interaction validation.',
        }
        (output / 'simulator-smoke.json').write_text(json.dumps(record, indent=2) + '\n')
        print('PASS: fresh simulator app launch and screenshot; interactive/device checks remain separate.')
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', simulator], capture_output=True)
        subprocess.run(['xcrun', 'simctl', 'delete', simulator], check=True)


if __name__ == '__main__':
    main()
