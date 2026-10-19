import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';

// Xcode names the IPA after the archived product, not CFBundleDisplayName.
export function findExportedIPA(directory) {
  const candidates = readdirSync(directory, { withFileTypes: true })
    .filter(entry => /\.ipa$/i.test(entry.name));
  if (candidates.length !== 1 || !candidates[0].isFile()) {
    throw new Error('Expected exactly one regular exported IPA file.');
  }
  return join(resolve(directory), candidates[0].name);
}

export function validatePreparedIPA(directory, preparedPath) {
  const ipa = findExportedIPA(directory);
  if (typeof preparedPath !== 'string' || resolve(preparedPath) !== ipa) {
    throw new Error('Unexpected prepared IPA path.');
  }
  return ipa;
}

export function decodeProfileEntitlements(xml) {
  // Full profiles also contain dates/certificate data, which are not JSON values.
  const decoded = spawnSync('python3', ['-c',
    "import json,plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); json.dump({k:p.get(k) for k in ('Entitlements','TeamIdentifier')},sys.stdout)"],
  {input: xml, encoding: 'utf8'});
  if (decoded.status !== 0) throw new Error('Invalid embedded provisioning profile.');
  return JSON.parse(decoded.stdout);
}

export function verifyDistributionEntitlements(info, signed, profile, {bundleID, teamID, icloudContainer, requiresPush}) {
  const fail = key => { throw new Error(`Distribution ${key} mismatch for ${bundleID}.`); };
  if (typeof icloudContainer !== 'string' || !icloudContainer || /[*$]/.test(icloudContainer)) fail('configured CloudKit container');
  const authorized = profile?.Entitlements ?? {};
  const applicationID = signed['application-identifier'] ?? signed['com.apple.application-identifier'];
  if (typeof applicationID !== 'string' || authorized['application-identifier'] !== applicationID ||
      profile?.TeamIdentifier?.length !== 1 || profile.TeamIdentifier[0] !== teamID) fail('embedded profile identity');
  // Profiles authorize sets of values; the final signature selects concrete values.
  const allows = (key, value) => {
    const values = Array.isArray(authorized[key]) ? authorized[key] : [authorized[key]];
    return values.some(item => item === value || item === '*');
  };
  for (const [key, value] of [
    ['com.apple.developer.icloud-container-identifiers', icloudContainer],
    ['com.apple.developer.icloud-services', 'CloudKit'],
  ]) {
    if (!Array.isArray(signed[key]) || !signed[key].includes(value)) fail('signed ' + key);
    for (const selected of signed[key]) {
      if (typeof selected !== 'string' || !selected.trim() || /[*$]/.test(selected)) fail('signed ' + key);
      if (!allows(key, selected)) fail('profile ' + key);
    }
  }
  const environment = 'com.apple.developer.icloud-container-environment';
  if (signed[environment] !== 'Production') fail('signed ' + environment);
  if (!allows(environment, 'Production')) fail('profile ' + environment);
  if (info.QuotaICloudContainer !== icloudContainer) fail('Info.plist CloudKit container');
  if (requiresPush) {
    if (signed['aps-environment'] !== 'production') fail('signed aps-environment');
    if (authorized['aps-environment'] !== 'production') fail('profile aps-environment');
    if (info.QuotaAPNSEnvironment !== 'production') fail('Info.plist APNs environment');
  }
}
