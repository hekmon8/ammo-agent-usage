// Shared by the local release command and CI; no credentials are read here.
import {createHash} from 'node:crypto';
import {lstatSync, readFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {validatePreparedIPA} from '../testflight-artifact.mjs';

export function distributionMode(env = process.env) {
  const mode = env.IOS_TESTFLIGHT_MODE ?? 'internal';
  if (!['internal', 'external-candidate'].includes(mode)) throw new Error('Choose internal or external-candidate TestFlight mode.');
  const legacy = env.IOS_TESTFLIGHT_INTERNAL_ONLY;
  if (legacy !== undefined && (legacy !== '1' || mode !== 'internal')) {
    throw new Error('IOS_TESTFLIGHT_INTERNAL_ONLY only supports 1 in internal mode; select candidate preparation explicitly with IOS_TESTFLIGHT_MODE.');
  }
  return mode;
}

// Every entry point that can upload or link a group must call this before work.
// Missing mode is accepted only for historical receipts already marked internal.
export function assertInternalRelease(receipt, env = process.env) {
  if (distributionMode(env) !== 'internal') throw new Error('External candidates are prepare-only; upload and readback are disabled.');
  if (receipt !== undefined && (!receipt || receipt.internalOnly !== true ||
      (Object.hasOwn(receipt, 'mode') && receipt.mode !== 'internal'))) {
    throw new Error('Only an internal prepared receipt can be uploaded or distributed; external candidates are prepare-only.');
  }
}

// CI uses fixed internal paths. Relabeling a candidate receipt must not permit
// uploads or group writes through an entry point below the local release script.
export function verifyInternalArtifact(receipt, {root = process.cwd(), env = process.env} = {}) {
  assertInternalRelease(receipt, env);
  root = resolve(root);
  const exportPath = resolve(root, '.build/TestFlight/export');
  const optionsPath = resolve(root, '.build/TestFlight/ExportOptions.plist');
  if (typeof receipt.ipa !== 'string' || dirname(resolve(root, receipt.ipa)) !== exportPath) {
    throw new Error('Internal IPA must use the internal CI export directory, not a candidate path.');
  }
  for (const path of [resolve(root, receipt.ipa), optionsPath]) {
    for (let ancestor = path; ancestor !== root; ancestor = dirname(ancestor)) {
      if (lstatSync(ancestor).isSymbolicLink()) throw new Error('Internal artifacts must not use symbolic links.');
    }
  }
  const ipa = validatePreparedIPA(exportPath, resolve(root, receipt.ipa));
  const optionsBytes = readFileSync(optionsPath);
  const digest = bytes => createHash('sha256').update(bytes).digest('hex');
  if (!/^[a-f0-9]{64}$/.test(receipt.sha256 || '') || digest(readFileSync(ipa)) !== receipt.sha256) {
    throw new Error('Internal IPA SHA-256 differs from the prepared receipt.');
  }
  if (!/^[a-f0-9]{64}$/.test(receipt.exportOptionsSha256 || '') || digest(optionsBytes) !== receipt.exportOptionsSha256) {
    throw new Error('Internal export options SHA-256 differs from the prepared receipt.');
  }
  // plistlib is available on both CI platforms; decode locally without invoking
  // signing tools or exposing profile names in command output or error messages.
  const decoded = spawnSync('python3', ['-c',
    "import json,plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); json.dump({k:p.get(k) for k in ('method','testFlightInternalTestingOnly')},sys.stdout)"],
  {input: optionsBytes, encoding: 'utf8', timeout: 10000});
  let options;
  try { options = decoded.status === 0 ? JSON.parse(decoded.stdout) : null; } catch { options = null; }
  if (options?.method !== 'app-store-connect' || options?.testFlightInternalTestingOnly !== true) {
    throw new Error('Internal artifact requires actual internal-only App Store Connect export options.');
  }
}

export function exportOptions(teamID, bundleID, env = process.env) {
  const options = {method: 'app-store-connect', teamID, signingStyle: 'automatic',
    testFlightInternalTestingOnly: distributionMode(env) === 'internal'};
  if (!env.IOS_SIGNING_STYLE) return options;
  if (env.IOS_SIGNING_STYLE !== 'manual') throw new Error('Only explicit manual CI signing is supported.');
  const profiles = JSON.parse(env.IOS_PROVISIONING_PROFILES || '{}');
  const expected = [bundleID, `${bundleID}.widgets`].sort();
  if (JSON.stringify(Object.keys(profiles).sort()) !== JSON.stringify(expected) ||
      Object.values(profiles).some(value => typeof value !== 'string' || !value.trim() || /[\r\n]/.test(value))) {
    throw new Error('Manual signing requires exact app and widget profile names.');
  }
  return {...options, signingStyle: 'manual', signingCertificate: 'Apple Distribution', provisioningProfiles: profiles};
}
