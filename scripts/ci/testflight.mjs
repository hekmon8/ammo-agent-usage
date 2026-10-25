#!/usr/bin/env node
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {api, assertBuildUnused, builds, internalGroup, list} from './asc.mjs';
import {assertInternalRelease, verifyInternalArtifact} from './signing-options.mjs';

const read = path => JSON.parse(readFileSync(path, 'utf8'));
const digest = value => createHash('sha256').update(value).digest('hex');
const command = (...args) => execFileSync(args[0], args.slice(1), {stdio: 'inherit'});
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function verifyGroup(receipt) {
  return internalGroup(receipt.appID, process.env.ASC_INTERNAL_GROUP_ID);
}

async function gates() {
  assertInternalRelease();
  if (process.env.TESTFLIGHT_ENABLED !== 'true' || process.env.CI_UPLOAD_AUTHORIZED !== 'true') throw new Error('Maintainer has not enabled protected internal releases.');
  const prepared = read('.build/TestFlight/prepared.json');
  verifyInternalArtifact(prepared);
  const ref = read('.build/ci/release-ref.json');
  const smoke = read('.build/ci/simulator-smoke.json');
  if (prepared.commit !== ref.commit || prepared.version !== ref.version || prepared.buildNumber !== ref.buildNumber || prepared.internalOnly !== true) throw new Error('Prepared artifact differs from protected tag.');
  if (smoke.commit !== ref.commit || smoke.launchSucceeded !== true ||
      smoke.screenshotSha256 !== digest(readFileSync('.build/ci/ios-simulator-smoke.png'))) throw new Error('Fresh simulator smoke evidence is missing or stale.');
  if (prepared.sha256 !== digest(readFileSync(prepared.ipa))) throw new Error('IPA changed after verification.');
  await verifyGroup(prepared);
  await assertBuildUnused(prepared.appID, prepared.version, prepared.buildNumber);
  const artifact = {appID: prepared.appID, bundleID: process.env.IOS_BUNDLE_ID, version: prepared.version, buildNumber: prepared.buildNumber, ipaSha256: prepared.sha256};
  const statements = {
    'TF-INTERNAL-owner-authorization': `Maintainer enabled TESTFLIGHT_ENABLED in the testflight-internal environment; protected ${ref.tag} at ${ref.tagObject}; triggering actor ${process.env.GITHUB_ACTOR}; workflow ${process.env.GITHUB_RUN_ID}. This records the configured release policy, not a fabricated human QA review.`,
    'TF-INTERNAL-signed-ipa': 'Existing testflight-ios.mjs --prepare verified signed app/widget identity, versions, entitlements, privacy manifests, and internal-only export; IPA hash matches prepared receipt.',
    'TF-INTERNAL-simulator-smoke': smoke.scope + ' Screenshot SHA-256: ' + smoke.screenshotSha256,
    'TF-INTERNAL-tester-group': 'Read App Store Connect: configured group belongs to this app, is internal, and already has at least one tester. Build linkage is checked after upload; no tester invitation or group creation occurred.',
  };
  mkdirSync('.release', {recursive: true, mode: 0o700});
  const records = [];
  for (const [gateID, statement] of Object.entries(statements)) {
    const evidence = '.release/' + gateID + '.json';
    const content = JSON.stringify({gateID, commit: ref.commit, artifact, statement}, null, 2) + '\n';
    writeFileSync(evidence, content, {mode: 0o600});
    records.push({id: gateID, evidence, commit: ref.commit, sha256: digest(content), verified: true,
      verifier: 'CI checks / maintainer-configured release policy', verifiedAt: new Date().toISOString()});
  }
  writeFileSync('.release/internal-testflight-gates.json', JSON.stringify({profile: 'internal-testflight', artifact, gates: records}, null, 2) + '\n', {mode: 0o600});
  command('node', 'scripts/testflight-ios.mjs', '--upload');
}

async function readback() {
  assertInternalRelease();
  const prepared = read('.build/TestFlight/prepared.json');
  verifyInternalArtifact(prepared);
  const ref = read('.build/ci/release-ref.json');
  const groupID = process.env.ASC_INTERNAL_GROUP_ID;
  const deadline = Date.now() + 25 * 60 * 1000;
  let linked = false;
  while (Date.now() < deadline) {
    const found = await builds(prepared.appID, prepared.version, prepared.buildNumber);
    if (found.length > 1) throw new Error('Ambiguous Apple build; no group mutation performed.');
    if (found.length === 1) {
      const build = found[0];
      const attributes = build.attributes;
      if (attributes.expired || ['FAILED', 'INVALID'].includes(attributes.processingState)) throw new Error('Apple rejected or expired this build.');
      if (attributes.processingState === 'VALID') {
        if (attributes.buildAudienceType !== 'INTERNAL_ONLY') throw new Error('Apple did not mark this build INTERNAL_ONLY.');
        await verifyGroup(prepared);
        const path = `/v1/betaGroups/${groupID}/relationships/builds`;
        const members = await list(path + '?limit=200');
        if (!members.some(item => item.id === build.id)) {
          if (linked) throw new Error('Group linkage is still missing after write; inspect ASC before retry.');
          await api(path, 'POST', {data: [{type: 'builds', id: build.id}]});
          linked = true;
        } else {
          const detail = (await api(`/v1/builds/${build.id}/buildBetaDetail`)).data;
          const state = detail?.attributes?.internalBuildState;
          if (state === 'IN_BETA_TESTING') {
            const receipt = {...ref, appID: prepared.appID, buildID: build.id, ipaSha256: prepared.sha256,
              processingState: 'VALID', audience: 'INTERNAL_ONLY', internalBuildState: state,
              // The public artifact binds the group without disclosing its internal identifier.
              internalGroupSha256: digest(groupID), groupLinked: true, verifiedAt: new Date().toISOString()};
            writeFileSync('.build/ci/testflight-receipt.json', JSON.stringify(receipt, null, 2) + '\n');
            console.log(`PASS: iOS ${prepared.version} (${prepared.buildNumber}) is VALID, INTERNAL_ONLY, and linked to the configured internal test group in IN_BETA_TESTING.`);
            return;
          }
          if (['MISSING_EXPORT_COMPLIANCE', 'PROCESSING_EXCEPTION', 'EXPIRED', 'IN_EXPORT_COMPLIANCE_REVIEW'].includes(state)) throw new Error(`Internal testing is blocked by Apple state ${state}; CI will not accept agreements or change compliance declarations.`);
        }
      }
    }
    console.log('Waiting for exact Apple build processing / internal availability (no upload retry).');
    await sleep(30000);
  }
  throw new Error('Apple readback timed out. Upload may have succeeded; inspect exact version/build before retrying.');
}

const handlers = {upload: gates, readback};
if (!handlers[process.argv[2]]) throw new Error('Choose upload or readback.');
handlers[process.argv[2]]().catch(error => {console.error(error.message); process.exitCode = 1;});
