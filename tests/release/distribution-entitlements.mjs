import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {decodeProfileEntitlements, verifyDistributionEntitlements} from '../../scripts/testflight-artifact.mjs';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/cloud-entitlements.TEST-ONLY.json', import.meta.url)));
const cloudKeys = ['com.apple.developer.icloud-container-identifiers', 'com.apple.developer.icloud-services', 'com.apple.developer.icloud-container-environment'];
function sample(role) {
  const f = structuredClone(fixture);
  const bundleID = 'org.example.ammo' + (role === 'widget' ? '.widgets' : '');
  f.options = {bundleID, teamID: f.teamID, icloudContainer: f.icloudContainer, requiresPush: role === 'app'};
  f.info = {QuotaICloudContainer: f.icloudContainer};
  f.signed['application-identifier'] = `${f.appIDPrefix}.${bundleID}`;
  f.profile.Entitlements['application-identifier'] = f.signed['application-identifier'];
  if (role === 'app') {
    f.signed['aps-environment'] = f.profile.Entitlements['aps-environment'] = 'production';
    f.info.QuotaAPNSEnvironment = 'production';
  }
  return f;
}
const verify = f => verifyDistributionEntitlements(f.info, f.signed, f.profile, f.options);

for (const role of ['app', 'widget']) {
  test(`${role}: production signature accepts a broader valid profile and an independent App ID prefix`, () => {
    assert.doesNotThrow(() => verify(sample(role)));
    const f = sample(role);
    f.profile.Entitlements[cloudKeys[1]] = ['CloudKit'];
    f.profile.Entitlements[cloudKeys[2]] = 'Production';
    assert.doesNotThrow(() => verify(f));
  });

  test(`${role}: missing or wrong signed CloudKit capabilities fail`, () => {
    for (const key of cloudKeys) {
      for (const value of [undefined, key === cloudKeys[2] ? 'Development' : ['unrelated']]) {
        const f = sample(role);
        f.signed[key] = value;
        assert.throws(() => verify(f), /Distribution signed com.apple.developer.icloud/);
      }
    }
    const f = sample(role);
    f.signed[cloudKeys[2]] = ['Production'];
    assert.throws(() => verify(f), /signed .*environment/);
  });

  test(`${role}: profile must authorize the selected container, service and production environment`, () => {
    for (const key of cloudKeys) {
      for (const value of [undefined, key === cloudKeys[2] ? ['Development'] : ['unrelated']]) {
        const f = sample(role);
        f.profile.Entitlements[key] = value;
        assert.throws(() => verify(f), /Distribution profile com.apple.developer.icloud/);
      }
    }
  });

  test(`${role}: every signed container and service must be concrete and authorized`, () => {
    for (const key of cloudKeys.slice(0, 2)) {
      for (const value of ['*', '$(UNRESOLVED)', '', null, 7, 'unrelated']) {
        const f = sample(role);
        f.profile.Entitlements[key] = [...f.signed[key]];
        f.signed[key].push(value);
        assert.throws(() => verify(f), /Distribution (signed|profile) com.apple.developer.icloud/);
      }
    }
    const f = sample(role);
    f.signed[cloudKeys[0]].push('iCloud.org.example.other');
    f.signed[cloudKeys[1]].push('CloudDocuments');
    assert.doesNotThrow(() => verify(f));
  });

  test(`${role}: Info.plist and configured CloudKit container must match`, () => {
    for (const value of [undefined, 'iCloud.org.example.other']) {
      const f = sample(role);
      f.info.QuotaICloudContainer = value;
      assert.throws(() => verify(f), /Info.plist CloudKit container/);
    }
    for (const value of [undefined, '', '*', '$(QI_ICLOUD_CONTAINER)']) {
      const f = sample(role);
      f.options.icloudContainer = value;
      assert.throws(() => verify(f), /configured CloudKit container/);
    }
  });

  test(`${role}: missing or unrelated embedded profiles fail identity binding`, () => {
    for (const profile of [undefined, {}, {...sample(role).profile, TeamIdentifier: ['OTHERTEAM1']}]) {
      assert.throws(() => verify({...sample(role), profile}), /embedded profile identity/);
    }
    const f = sample(role);
    f.profile.Entitlements['application-identifier'] = 'OTHERPRFX1.' + f.options.bundleID;
    assert.throws(() => verify(f), /embedded profile identity/);
  });
}

test('app requires production APNs in signature, profile and runtime configuration', () => {
  for (const target of ['signed', 'profile', 'info']) {
    for (const value of [undefined, 'development', 'sandbox', 'Production']) {
      const f = sample('app');
      if (target === 'profile') f.profile.Entitlements['aps-environment'] = value;
      else if (target === 'info') f.info.QuotaAPNSEnvironment = value;
      else f.signed['aps-environment'] = value;
      assert.throws(() => verify(f), /aps-environment|APNs environment/);
    }
  }
});

test('widget without APNs capabilities is valid and gains no new entitlement', () => {
  const f = sample('widget');
  const before = structuredClone(f);
  verify(f);
  assert.deepEqual(f, before);
  assert.equal(Object.hasOwn(f.signed, 'aps-environment'), false);
});

test('profile decoder handles synthetic dates and certificate data without exposing them', () => {
  const xml = `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
    <key>DeveloperCertificates</key><array><data>c3ludGhldGlj</data></array>
    <key>TeamIdentifier</key><array><string>ABCDEFGHIJ</string></array>
    <key>Entitlements</key><dict><key>aps-environment</key><string>production</string></dict>
  </dict></plist>`;
  assert.deepEqual(decodeProfileEntitlements(xml), {TeamIdentifier: ['ABCDEFGHIJ'], Entitlements: {'aps-environment': 'production'}});
  assert.throws(() => decodeProfileEntitlements('not a plist'), /Invalid embedded provisioning profile/);
});
