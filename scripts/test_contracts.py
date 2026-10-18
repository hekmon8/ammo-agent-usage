#!/usr/bin/env python3
"""Executable reference semantics and synthetic crypto tests; not production runtime."""
from __future__ import annotations
import base64
import copy
import hashlib
import json
import unittest
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from jsonschema import Draft202012Validator, FormatChecker, ValidationError
ROOT=Path(__file__).resolve().parents[1]
def load(name): return json.loads((ROOT/name).read_text(encoding='utf-8'))
def fixture(name): return load('contracts/fixtures/'+name+'.json')
def dt(s): return datetime.fromisoformat(s.replace('Z','+00:00'))
def unb64(s): return base64.urlsafe_b64decode(s+'='*((-len(s))%4))
def normalize_used(value):
    """Source numeric percentage -> integer remaining basis points, half-up rounding."""
    if isinstance(value, bool): raise ValueError('Boolean is not a quota')
    try: n=Decimal(str(value))
    except InvalidOperation as e: raise ValueError('Invalid percentage') from e
    if not n.is_finite() or n<0 or n>100: raise ValueError('Out-of-range percentage')
    return 10000-int((n*100).quantize(Decimal('1'),rounding=ROUND_HALF_UP))
def state(q, now):
    if q['fetchOutcome']=='auth_required': return 'authRequired'
    if q['availability']=='unavailable': return 'unavailable'
    if q['availability']=='unlimited': return 'unlimited'
    reset=q['window']['resetsAt']
    if reset and dt(reset)<=now and (q['observedAt'] is None or dt(q['observedAt'])<dt(reset)):
        return 'resetPending'
    if q['staleAt'] is None or dt(q['staleAt'])<=now: return 'stale'
    if q['remainingBps'] is not None and q['remainingBps']<=1000: return 'low'
    return 'fresh'
def trend_segments(points, interval_seconds=300):
    out=[]; current=[]; prev=None
    for p in points:
        if p['remainingBps'] is None:
            if current:out.append(current)
            current=[];prev=None;continue
        gap=prev is not None and (p['segmentId']!=prev['segmentId'] or not 0<(dt(p['observedAt'])-dt(prev['observedAt'])).total_seconds()<=2*interval_seconds)
        if gap:
            if current:out.append(current)
            current=[]
        current.append(p);prev=p
    if current:out.append(current)
    return out
# This models sequential admission only. Worker implementation still requires an
# atomic DB operation, with authentication/revocation checks in the same boundary.
def admit(old, incoming, active_epoch):
    if incoming['sourceEpoch']!=active_epoch:return 'reject_epoch'
    if old is None:return 'accept'
    if incoming['sequence']<old['sequence']:return 'reject_old'
    if incoming['sequence']==old['sequence']:
        return 'idempotent' if incoming['contentHash']==old['contentHash'] else 'reject_conflict'
    return 'accept'
class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.valid=Draft202012Validator(load('contracts/snapshot.schema.json'),format_checker=FormatChecker())
        cls.now=dt('2026-09-05T01:41:00Z')
    def test_01_used_to_remaining(self):self.assertEqual(normalize_used(32),6800)
    def test_02_boundaries(self):self.assertEqual([normalize_used(0),normalize_used(100)],[10000,0])
    def test_03_rounding(self):self.assertEqual(normalize_used('32.005'),6799)
    def test_04_invalid(self):
        for x in [-1,101,'NaN','Infinity',True,None,'abc']:
            with self.subTest(x=x),self.assertRaises(ValueError):normalize_used(x)
    def test_05_all_fixtures(self):
        for p in sorted((ROOT/'contracts/fixtures').glob('*.json')):
            with self.subTest(p=p.name):self.valid.validate(json.loads(p.read_text()))
    def test_06_unknown_not_zero(self):
        q=fixture('05-unavailable')['windows'][0]
        self.assertIsNone(q['remainingBps']);self.assertEqual(state(q,self.now),'unavailable')
    def test_07_unlimited(self):self.assertEqual(state(fixture('06-unlimited')['windows'][0],self.now),'unlimited')
    def test_08_stale(self):self.assertEqual(state(fixture('03-stale')['windows'][0],self.now),'stale')
    def test_09_reset_not_refill(self):
        q=fixture('04-reset-pending')['windows'][0]
        self.assertEqual(state(q,self.now),'resetPending');self.assertEqual(q['remainingBps'],6800)
    def test_10_auth(self):self.assertEqual(state(fixture('07-auth-required')['windows'][0],self.now),'authRequired')
    def test_11_low(self):self.assertEqual(state(fixture('02-low')['windows'][0],self.now),'low')
    def test_12_fresh(self):self.assertEqual(state(fixture('01-fresh')['windows'][0],self.now),'fresh')
    def test_13_recapture_not_fresh(self):
        j=fixture('03-stale');j['capturedAt']='2026-09-05T01:41:00Z'
        self.assertEqual(state(j['windows'][0],self.now),'stale')
    def test_14_windows_separate(self):
        j=fixture('08-multiple-windows');self.assertEqual([q['remainingBps'] for q in j['windows']],[6800,4200,2400])
        self.assertEqual(len({q['id'] for q in j['windows']}),3)
    def test_15_money(self):
        q=fixture('09-money')['windows'][0];self.assertEqual(Decimal(q['amount']),Decimal('42.60'))
        self.assertIsNone(q['remainingBps']);self.assertEqual(q['currency'],'USD')
    def test_16_schema_unknown_numeric_forbidden(self):
        j=fixture('05-unavailable');j['windows'][0]['remainingBps']=0
        with self.assertRaises(ValidationError):self.valid.validate(j)
    def test_17_schema_additional_fields_forbidden(self):
        j=fixture('01-fresh');j['accessToken']='NOT-A-REAL-SECRET'
        with self.assertRaises(ValidationError):self.valid.validate(j)
    def test_18_contiguous_history(self):
        self.assertEqual(len(trend_segments(fixture('01-fresh')['windows'][0]['history'])),1)
    def test_19_gap_not_interpolated(self):
        segments=trend_segments(fixture('10-gap')['windows'][0]['history'],interval_seconds=600)
        self.assertEqual([len(s) for s in segments],[2,2])
    def test_20_reset_segment(self):
        pts=copy.deepcopy(fixture('01-fresh')['windows'][0]['history']);pts[3]['segmentId']='new-period'
        self.assertGreaterEqual(len(trend_segments(pts)),2)
    def test_21_monotonic_idempotence(self):
        e=load('contracts/examples/envelope.example.json')
        self.assertEqual(admit(e,e,e['sourceEpoch']),'idempotent')
        n=dict(e,sequence=e['sequence']-1);self.assertEqual(admit(e,n,e['sourceEpoch']),'reject_old')
        n=dict(e,contentHash='0'*64);self.assertEqual(admit(e,n,e['sourceEpoch']),'reject_conflict')
        n=dict(e,sourceEpoch='other');self.assertEqual(admit(e,n,e['sourceEpoch']),'reject_epoch')
    def test_22_crypto_roundtrip(self):
        v=load('contracts/examples/crypto-golden-vector.TEST-ONLY.json');e=load('contracts/examples/envelope.example.json')
        nonce,ct,tag=[unb64(e[k]) for k in ['nonce','ciphertext','tag']];aad=v['aadUtf8'].encode();msg=aad+b'\n'+nonce+ct+tag
        self.assertEqual(len(nonce),12);self.assertEqual(len(tag),16)
        self.assertEqual(hashlib.sha256(msg).hexdigest(),e['contentHash'])
        Ed25519PublicKey.from_public_bytes(unb64(v['sourceSigningPublicKeyBase64url'])).verify(unb64(e['signature']),msg)
        plain=AESGCM(unb64(v['aesKeyBase64url'])).decrypt(nonce,ct+tag,aad)
        self.assertEqual(json.loads(plain),fixture('01-fresh'))
    def test_23_signature_tampering(self):
        v=load('contracts/examples/crypto-golden-vector.TEST-ONLY.json');e=load('contracts/examples/envelope.example.json')
        msg=v['aadUtf8'].encode()+b'\n'+unb64(e['nonce'])+unb64(e['ciphertext'])+unb64(e['tag'])+b'bad'
        with self.assertRaises(InvalidSignature):
            Ed25519PublicKey.from_public_bytes(unb64(v['sourceSigningPublicKeyBase64url'])).verify(unb64(e['signature']),msg)
    def test_24_gcm_aad_tampering(self):
        v=load('contracts/examples/crypto-golden-vector.TEST-ONLY.json');e=load('contracts/examples/envelope.example.json')
        with self.assertRaises(InvalidTag):
            AESGCM(unb64(v['aesKeyBase64url'])).decrypt(unb64(e['nonce']),unb64(e['ciphertext'])+unb64(e['tag']),b'wrong-workspace')
    def test_25_live_projection_timestamps(self):
        live=load('contracts/examples/live-activity-content.example.json')['contentState'];q=fixture('01-fresh')['windows'][0]
        self.assertEqual(live['observedAt'],int(dt(q['observedAt']).timestamp()))
        self.assertLess(live['staleAt'],live['resetsAt'])
    def test_26_fixed_window_duration(self):
        for p in (ROOT/'contracts/fixtures').glob('*.json'):
            for q in json.loads(p.read_text())['windows']:
                w=q['window']
                if w['kind']=='fixed' and all(w[k] is not None for k in ['startsAt','resetsAt','durationSeconds']):
                    self.assertEqual((dt(w['resetsAt'])-dt(w['startsAt'])).total_seconds(),w['durationSeconds'])
    def test_27_missing_key_is_not_null(self):
        j=fixture('01-fresh');del j['windows'][0]['amount']
        with self.assertRaises(ValidationError):self.valid.validate(j)
class TokenUsageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.validator = Draft202012Validator(load('contracts/token-usage.schema.json'), format_checker=FormatChecker())
        cls.example = load('contracts/examples/token-usage.TEST-ONLY.json')
    def test_usage_schema_is_separate_and_strict(self):
        self.validator.validate(self.example)
        self.assertLessEqual(len(json.dumps(self.example).encode()), 131072)
        quota = Draft202012Validator(load('contracts/snapshot.schema.json'), format_checker=FormatChecker())
        with self.assertRaises(ValidationError): quota.validate(self.example)
        for path in [(), ('sources', 0), ('buckets', 0), ('buckets', 0, 'tokens')]:
            value = copy.deepcopy(self.example); target = value
            for part in path: target = target[part]
            target['rawMessage'] = 'synthetic must not sync'
            with self.subTest(path=path), self.assertRaises(ValidationError): self.validator.validate(value)
    def test_usage_missing_null_and_invalid_counts_rejected(self):
        for field in self.example:
            value = copy.deepcopy(self.example); del value[field]
            with self.subTest(field=field), self.assertRaises(ValidationError): self.validator.validate(value)
        for invalid in [-1, True, None, 2251799813685248, 1.5, '123']:
            value = copy.deepcopy(self.example); value['buckets'][0]['tokens']['output'] = invalid
            with self.subTest(count=invalid), self.assertRaises(ValidationError): self.validator.validate(value)
        for field in ['scannedAt', 'latestEventAt', 'diagnostic']:
            value = copy.deepcopy(self.example); value['sources'][0][field] = None
            with self.subTest(field=field), self.assertRaises(ValidationError): self.validator.validate(value)
    def test_usage_privacy_and_bounds(self):
        for diagnostic in ['/Users/example/project', 'raw transcript text', 'a' * 81]:
            value = copy.deepcopy(self.example); value['sources'][0]['diagnostic'] = diagnostic
            with self.assertRaises(ValidationError): self.validator.validate(value)
        for field, count in [('sources', 3), ('buckets', 801)]:
            value = copy.deepcopy(self.example); value[field] = [value[field][0]] * count
            with self.assertRaises(ValidationError): self.validator.validate(value)
        for agent in ['unknown', 'claudeCode']:
            value = copy.deepcopy(self.example); value['buckets'][0]['agent'] = agent
            with self.assertRaises(ValidationError): self.validator.validate(value)
    def test_usage_crypto_domain_cannot_replay_quota(self):
        # Derive a synthetic usage encryption vector with fresh independent test
        # material. The same key cannot decrypt across the two protocol domains.
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        key = bytes([19]) * 32; nonce = bytes([23]) * 12
        signer = Ed25519PrivateKey.from_private_bytes(bytes([29]) * 32)
        header = b'QI-USAGE|1|ws_test|mac_test|epoch_test|1|key_test'
        plain = json.dumps(self.example, separators=(',', ':')).encode()
        sealed = AESGCM(key).encrypt(nonce, plain, header)
        signed = header + b'\n' + nonce + sealed
        signature = signer.sign(signed)
        signer.public_key().verify(signature, signed)
        self.assertEqual(json.loads(AESGCM(key).decrypt(nonce, sealed, header)), self.example)
        quota_header = header.replace(b'QI-USAGE|1|', b'QI|1|')
        with self.assertRaises(InvalidTag): AESGCM(key).decrypt(nonce, sealed, quota_header)
        with self.assertRaises(InvalidSignature): signer.public_key().verify(signature, quota_header + b'\n' + nonce + sealed)
        enc = lambda data: base64.urlsafe_b64encode(data).decode().rstrip('=')
        envelope = dict(schemaVersion='1.0.0',workspaceId='ws_test',sourceDeviceId='mac_test',sourceEpoch='epoch_test',sequence=1,keyId='key_test',nonce=enc(nonce),ciphertext=enc(sealed[:-16]),tag=enc(sealed[-16:]),signature=enc(signature),contentHash=hashlib.sha256(signed).hexdigest())
        validator = Draft202012Validator(load('contracts/usage-envelope.schema.json'))
        validator.validate(envelope)
        envelope['ciphertext'] = enc(bytes(131073))
        with self.assertRaises(ValidationError): validator.validate(envelope)

class ActivityV2ContractTests(unittest.TestCase):
    def setUp(self):
        self.example = load('contracts/examples/live-activity-v2-content.example.json')
        self.validator = Draft202012Validator(load('contracts/live-activity-v2-content.schema.json'))

    def test_v2_example_keeps_independent_rows_and_explicit_nulls(self):
        self.validator.validate(self.example)
        self.assertEqual([x['sequence'] for x in self.example['rows']], [19, 0])
        self.assertIsNone(self.example['rows'][1]['remainingBps'])
        self.assertLess(len(json.dumps({'aps': {'timestamp': 1791334800, 'event': 'update', 'content-state': self.example}}, ensure_ascii=False).encode()), 1024)

    def test_v2_contract_rejects_account_leaks_missing_null_and_extra_rows(self):
        for mutation in ['accountId', 'label', 'extra-row', 'missing-null', 'v1']:
            payload = copy.deepcopy(self.example)
            if mutation == 'extra-row': payload['rows'].append(copy.deepcopy(payload['rows'][0]))
            elif mutation == 'missing-null': del payload['rows'][1]['remainingBps']
            elif mutation == 'v1': payload['version'] = 1
            else: payload['rows'][0][mutation] = 'private'
            with self.assertRaises(ValidationError): self.validator.validate(payload)

if __name__=='__main__':unittest.main(verbosity=2)
