#!/usr/bin/env python3
"""Read-only binary release evidence gate; never manufactures device proof."""
import argparse, datetime, hashlib, json, re, subprocess, sys
from pathlib import Path

REQUIRED = {'P0-03-real-provider', 'P0-04-APNs-device', 'MAC-01-02-displays-spaces',
            'IOS-device-matrix', 'UX-01-accessibility', 'PERF-01-04-complete-duration',
            'LEGAL-01-license-owner-confirmation', 'P5-signing-entitlements-privacy',
            'P5-owner-release-authorization'}
INTERNAL_TESTFLIGHT_REQUIRED = {'TF-INTERNAL-owner-authorization',
                                'TF-INTERNAL-signed-ipa',
                                'TF-INTERNAL-simulator-smoke',
                                'TF-INTERNAL-tester-group'}

def validate(root, document, commit, profile='formal', expected_artifact=None):
    failures = []
    evidence_root = (root/'.release').resolve()
    seen_evidence = set()
    required = REQUIRED if profile == 'formal' else INTERNAL_TESTFLIGHT_REQUIRED
    if profile not in ('formal', 'internal-testflight'):
        return ['unknown release profile']
    if not isinstance(document, dict):
        return ['invalid gate document']
    if profile == 'internal-testflight':
        if document.get('profile') != profile or not expected_artifact or document.get('artifact') != expected_artifact:
            failures.append('internal TestFlight artifact or profile mismatch')
    elif document.get('profile', 'formal') != 'formal':
        failures.append('formal release profile mismatch')
    gates = document.get('gates', [])
    if not isinstance(gates, list) or any(not isinstance(g, dict) for g in gates):
        return failures + ['invalid gate list']
    if {g.get('id') for g in gates} != required or len(gates) != len(required):
        failures.append('required gate set missing or duplicated')
    for gate in gates:
        name = gate.get('id', 'unknown')
        try:
            if gate.get('verified') is not True or gate.get('commit') != commit: raise ValueError()
            relative = Path(gate['evidence'])
            if relative.is_absolute(): raise ValueError()
            evidence = (root/relative).resolve(strict=True)
            if not evidence.is_relative_to(evidence_root) or not evidence.is_file() or evidence in seen_evidence: raise ValueError()
            seen_evidence.add(evidence)
            data = evidence.read_bytes()
            if profile == 'internal-testflight':
                record = json.loads(data)
                if not isinstance(record, dict) or record.get('gateID') != name or record.get('commit') != commit or record.get('artifact') != expected_artifact or not isinstance(record.get('statement'), str) or not record['statement'].strip(): raise ValueError()
            elif not data.strip() or name.encode() not in data: raise ValueError()
            if not re.fullmatch('[a-f0-9]{64}', gate.get('sha256', '')) or hashlib.sha256(data).hexdigest() != gate['sha256']: raise ValueError()
            if not isinstance(gate.get('verifier'), str) or not gate['verifier'].strip(): raise ValueError()
            when = datetime.datetime.fromisoformat(gate['verifiedAt'].replace('Z', '+00:00'))
            if when.tzinfo is None or when > datetime.datetime.now(datetime.timezone.utc): raise ValueError()
        except (ValueError, KeyError, TypeError, OSError): failures.append(name)
    return failures

def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=('formal', 'internal-testflight'), default='formal')
    parser.add_argument('--gates', type=Path)
    for name in ('app-id', 'bundle-id', 'version', 'build-number', 'ipa-sha256'):
        parser.add_argument('--' + name)
    args = parser.parse_args()
    gates_path = args.gates or root/'.release'/('internal-testflight-gates.json' if args.profile == 'internal-testflight' else 'gates.json')
    artifact = None
    if args.profile == 'internal-testflight':
        artifact = {'appID': args.app_id, 'bundleID': args.bundle_id, 'version': args.version,
                    'buildNumber': args.build_number, 'ipaSha256': args.ipa_sha256}
        if any(not value for value in artifact.values()) or not re.fullmatch('[a-f0-9]{64}', args.ipa_sha256 or ''):
            parser.error('internal TestFlight requires exact app, version, build and IPA SHA-256')
    try:
        commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
        failures = validate(root, json.loads(gates_path.read_text()), commit, args.profile, artifact)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print('RELEASE BLOCKED: evidence unavailable or invalid: '+str(exc)); return 3
    if failures:
        print('RELEASE BLOCKED: '+', '.join(failures)); return 3
    print('PASS: '+args.profile+' evidence is bound to this commit and artifact; recorded verifiers remain responsible for observational claims.')
    return 0

if __name__ == '__main__': sys.exit(main())
