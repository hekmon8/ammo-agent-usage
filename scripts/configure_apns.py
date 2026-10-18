#!/usr/bin/env python3
"""Validate all APNs inputs before submitting one bulk secrets update."""
import argparse, json, os, re, subprocess, sys
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.parse import urlparse

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('key', type=Path)
    parser.add_argument('topic')
    parser.add_argument('config', type=Path)
    parser.add_argument('endpoint')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    key, config = args.key.resolve(strict=True), args.config.resolve(strict=True)
    team = os.environ.get('APNS_TEAM_ID', '')
    account = os.environ.get('CLOUDFLARE_ACCOUNT_ID', '')
    match = re.fullmatch(r'AuthKey_([A-Z0-9]{10})\.p8', key.name)
    if not match or not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Expected AuthKey_<10-char ID>.p8 and APNS_TEAM_ID.')
    if not re.fullmatch(r'[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+', args.topic):
        raise ValueError('Invalid APNs topic.')
    if not re.fullmatch(r'https://[a-zA-Z0-9.-]+', args.endpoint):
        raise ValueError('Use the exact HTTPS Worker origin, without a path.')
    if not re.fullmatch(r'[a-f0-9]{32}', account):
        raise ValueError('Set CLOUDFLARE_ACCOUNT_ID explicitly for the deployment owner.')
    material = key.read_text()
    # Validate the P-256 key without printing its contents.
    check = subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-text_pub', '-noout'], capture_output=True)
    if check.returncode or b'prime256v1' not in check.stdout:
        raise ValueError('APNs key must be a valid P-256 private key.')
    payload = dict(APNS_TEAM_ID=team, APNS_KEY_ID=match[1], APNS_PRIVATE_KEY=material, APNS_TOPIC=args.topic)
    root = Path(__file__).resolve().parents[1]
    wrangler = root/'workers/lite/node_modules/.bin/wrangler'
    if args.dry_run:
        print('Validated key and configuration paths; no remote changes.'); return
    # Bind the endpoint to the account and Worker before touching any secrets.
    token = os.environ.get('CLOUDFLARE_API_TOKEN', '')
    if not token: raise ValueError('Set CLOUDFLARE_API_TOKEN for target verification.')
    # This helper accepts JSON config (JSON syntax is also valid .jsonc).
    deployment = json.loads(config.read_text())
    if deployment.get('account_id') not in (None, account):
        raise ValueError('Configured account_id differs from CLOUDFLARE_ACCOUNT_ID.')
    name = deployment.get('name', '')
    if not re.fullmatch(r'[a-z0-9-]+', name): raise ValueError('Invalid Worker name.')
    def api(path):
        request = Request('https://api.cloudflare.com/client/v4/accounts/'+account+path,
                          headers={'Authorization': 'Bearer '+token})
        with urlopen(request, timeout=20) as response: data = json.load(response)
        if not data.get('success'): raise RuntimeError('Could not verify deployment target.')
        return data['result']
    host = urlparse(args.endpoint).hostname
    subdomain = api('/workers/subdomain').get('subdomain')
    hosts = {name+'.'+subdomain+'.workers.dev'} if subdomain else set()
    hosts.update(d['hostname'] for d in api('/workers/domains')
                 if d.get('service') == name and d.get('environment', 'production') == 'production')
    if host not in hosts: raise ValueError('Endpoint does not belong to the configured Worker/account.')
    # One bulk update avoids the four independently deployed partial states.
    result = subprocess.run([str(wrangler), 'secret', 'bulk', '--config', str(config)],
                            input=json.dumps(payload), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Bulk update failed; inspect deployment state before retry. Restore the previous complete secret set if needed.')
    result = subprocess.run([str(wrangler), 'secret', 'list', '--config', str(config)], text=True, capture_output=True)
    if result.returncode or not set(payload) <= {entry['name'] for entry in json.loads(result.stdout)}:
        raise RuntimeError('Could not verify all four secret names after update.')
    with urlopen(args.endpoint+'/v1/capabilities', timeout=15) as response:
        if json.load(response).get('pushMode') != 'own_team':
            raise RuntimeError('Target endpoint has not confirmed own_team; inspect deployment state.')
    print('All four secret names present; endpoint advertises own_team. Verify delivery on a signed device.')

if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print(str(exc), file=sys.stderr); sys.exit(1)
