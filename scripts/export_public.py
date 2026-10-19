#!/usr/bin/env python3
"""Export an explicit source allowlist from a clean commit, without Git history."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'.gitignore', '.gitleaks.toml', 'README.md', 'README.zh-CN.md', 'LICENSE', 'NOTICE', 'CONTRIBUTING.md',
              'SECURITY.md', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md', 'SOURCE.md',
              'Package.swift', 'Package.resolved', 'package.json', 'package-lock.json',
              'project.yml', 'toolchain.json'}
TREES = {'apps', 'native', 'extensions', 'contracts', 'tests', 'third_party'}
SCRIPTS = {'check_apple.sh', 'check_cli_mcp.py', 'check_l10n.py', 'configure-apns.sh',
           'configure_apns.py', 'prepare_ts_fixtures.py', 'release_preflight.py',
           'requirements.txt', 'requirements.lock.txt', 'test_contracts.py',
           'testflight-ios.mjs', 'testflight-artifact.mjs', 'export_public.py'}

def allowed(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or any(part in {'.git', '.build', 'node_modules', '.wrangler', '__pycache__'} for part in p.parts):
        return False
    if any(part.startswith('.env') or part == '.dev.vars' or '.local.' in part for part in p.parts):
        return False
    if p.suffix in {'.p8', '.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db', '.log', '.mp4', '.pdf'}:
        return False
    if len(p.parts) == 1: return name in ROOT_FILES
    if p.parts[0] in TREES: return True
    if p.parts[0] == 'packages': return p.parts[1] != 'QuotaProviderReference' and p.name != 'CLAUDE.md'
    if p.parts[0] == 'scripts':
        return (len(p.parts) == 2 and p.name in SCRIPTS) or (len(p.parts) >= 3 and p.parts[1] == 'ci')
    if p.parts[:2] == ('.github', 'workflows') and p.suffix in {'.yml', '.yaml'}: return True
    if name in {'docs/images/macos-quotas.png', 'docs/images/macos-usage.png',
                'docs/images/ios-first-launch.png'}: return True
    if name in {'Ammo.xcworkspace/contents.xcworkspacedata', 'config/Signing.xcconfig',
                'docs/open-source-release.md', 'docs/05-provider-framework.md',
                'docs/16-localization.md', 'docs/17-platform-billing.md', 'docs/18-token-usage.md',
                'docs/28-local-reset-reminders.md', 'docs/29-local-token-coverage-cost.md',
                'docs/github-actions.md'}: return True
    if name.startswith('workers/lite/'):
        return p.parts[2] in {'src', 'test', 'migrations'} or name in {
            'workers/lite/package.json', 'workers/lite/package-lock.json',
            'workers/lite/tsconfig.json', 'workers/lite/wrangler.jsonc', 'workers/lite/README.md',
            'workers/lite/INVARIANTS.md'}
    return False

def export(root, destination):
    if destination.exists(): raise ValueError('Destination must not exist; existing data is never replaced.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=root):
        raise ValueError('Commit reviewed inputs first; export requires a clean working tree.')
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', 'HEAD'], cwd=root, text=True).splitlines()
    selected = sorted(n for n in names if allowed(n))
    if 'LICENSE' not in selected: raise ValueError('Project license must be confirmed and committed before export.')
    manifest = {'format': 1, 'historyIncluded': False, 'files': []}
    # Read Git blobs, never follow filesystem symlinks into private local files.
    blobs = []
    for name in selected:
        entry = subprocess.check_output(['git', 'ls-tree', 'HEAD', '--', name], cwd=root, text=True)
        if not entry.startswith(('100644 ', '100755 ')): raise ValueError('Only regular files may be exported: '+name)
        data = subprocess.check_output(['git', 'show', 'HEAD:'+name], cwd=root)
        blobs.append((name, data, entry.startswith('100755 ')))
    destination.mkdir(parents=True)
    for name, data, executable in blobs:
        target = destination/name; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data); target.chmod(0o755 if executable else 0o644)
        manifest['files'].append({'path': name, 'sha256': hashlib.sha256(data).hexdigest()})
    (destination/'PUBLIC_MANIFEST.json').write_text(json.dumps(manifest, indent=2)+'\n')
    return len(blobs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(f'Exported {export(ROOT, args.output.resolve())} files without history.')

if __name__ == '__main__': main()
