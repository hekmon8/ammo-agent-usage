import test from 'node:test';
import assert from 'node:assert/strict';
import {exportOptions} from './signing-options.mjs';
import {parseTag, protectsTag, successfulChecks} from './release-ref.mjs';
import {builds, internalGroup, list} from './asc.mjs';

test('manual export uses exactly the app and widget profiles and retains internal-only', () => {
  const defaults = exportOptions('ABCDEFGHIJ', 'org.example.ammo', {});
  assert.equal(defaults.signingStyle, 'automatic');
  const profiles = {'org.example.ammo': 'App Store App', 'org.example.ammo.widgets': 'App Store Widget'};
  const options = exportOptions('ABCDEFGHIJ', 'org.example.ammo', {IOS_SIGNING_STYLE: 'manual', IOS_PROVISIONING_PROFILES: JSON.stringify(profiles)});
  assert.equal(options.signingStyle, 'manual');
  assert.equal(options.testFlightInternalTestingOnly, true);
  assert.deepEqual(options.provisioningProfiles, profiles);
  for (const invalid of [{}, {'org.example.ammo': 'App'}, {...profiles, other: 'Other'}, {...profiles, 'org.example.ammo': 'unsafe\nname'}]) {
    assert.throws(() => exportOptions('ABCDEFGHIJ', 'org.example.ammo', {IOS_SIGNING_STYLE: 'manual', IOS_PROVISIONING_PROFILES: JSON.stringify(invalid)}), /exact app and widget/);
  }
  assert.throws(() => exportOptions('ABCDEFGHIJ', 'org.example.ammo', {IOS_SIGNING_STYLE: 'external'}), /explicit manual/);
});

test('release selector rejects ambiguous tags and build-number injection', () => {
  assert.deepEqual(parseTag('testflight/ios/v0.1.4-b11'), {version: '0.1.4', buildNumber: '11'});
  for (const value of ['main', 'v0.1.4', 'testflight/ios/v0.1.4-b0', 'testflight/macos/v0.1.4-b11', 'testflight/ios/v0.1.4-b1\nrun']) {
    assert.throws(() => parseTag(value));
  }
});

test('tag rules must actively restrict creation, update and deletion without exclusions', () => {
  const ruleset = {target: 'tag', enforcement: 'active', conditions: {ref_name: {include: ['refs/tags/testflight/ios/**'], exclude: []}}, rules: ['creation', 'update', 'deletion'].map(type => ({type}))};
  assert.equal(protectsTag(ruleset, 'testflight/ios/v0.1.4-b11'), true);
  for (const patch of [{enforcement: 'disabled'}, {target: 'branch'}, {rules: [{type: 'deletion'}]}, {conditions: {ref_name: {include: ['~ALL'], exclude: ['refs/tags/testflight/**']}}}]) {
    assert.equal(Boolean(protectsTag({...ruleset, ...patch}, 'testflight/ios/v0.1.4-b11')), false);
  }
});

test('release checks must succeed for every required job at the exact default-branch commit', () => {
  const run = {head_sha: 'reviewed', head_branch: 'main', event: 'push', status: 'completed', conclusion: 'success'};
  const jobs = ['contracts-worker', 'ios-simulator', 'macos', 'secrets'].map(name => ({name, status: 'completed', conclusion: 'success'}));
  assert.equal(successfulChecks(run, jobs, 'reviewed', 'main'), true);
  for (const patch of [{head_sha: 'stale'}, {head_branch: 'feature'}, {event: 'pull_request'}, {conclusion: 'failure'}]) {
    assert.equal(successfulChecks({...run, ...patch}, jobs, 'reviewed', 'main'), false);
  }
  assert.equal(successfulChecks(run, jobs.slice(0, -1), 'reviewed', 'main'), false);
  assert.equal(successfulChecks(run, jobs.map(job => ({...job, conclusion: 'skipped'})), 'reviewed', 'main'), false);
});

test('build lookup scopes marketing version, iOS platform and exact build number', async () => {
  const calls = [];
  const request = async path => {
    calls.push(new URL(path, 'https://api.appstoreconnect.apple.com'));
    if (path.startsWith('/v1/preReleaseVersions')) return {data: [{id: 'version1', attributes: {version: '0.1.4', platform: 'IOS'}}]};
    return {data: [{id: 'build1', attributes: {version: '11', processingState: 'VALID'}}]};
  };
  const result = await builds('app1', '0.1.4', '11', request);
  assert.equal(result[0].id, 'build1');
  assert.equal(calls[0].searchParams.get('filter[platform]'), 'IOS');
  assert.equal(calls[0].searchParams.get('filter[version]'), '0.1.4');
  assert.equal(calls[1].searchParams.get('filter[preReleaseVersion]'), 'version1');
  assert.equal(calls[1].searchParams.get('filter[version]'), '11');
  await assert.rejects(() => builds('app1', '0.1.4', '11', async path => path.startsWith('/v1/preReleaseVersions') ?
    {data: [{id: 'v', attributes: {version: '0.1.4', platform: 'IOS'}}]} : {data: [{attributes: {version: '12'}}]}), /different build/);
  assert.deepEqual(await builds('app1', '0.1.4', '11', async () => ({data: []})), []);
});

test('group gate rejects external, empty and wrong-app groups without mutation', async () => {
  const fixture = (internal = true, app = 'app1', testers = [{id: 'existing'}]) => async (path, method) => {
    assert.equal(method, undefined, 'readiness gate is read-only');
    if (path.includes('/relationships/app')) return {data: {id: app}};
    if (path.includes('/relationships/betaTesters')) return {data: testers};
    return {data: {id: 'group1', attributes: {isInternalGroup: internal}}};
  };
  assert.equal((await internalGroup('app1', 'group1', fixture())).id, 'group1');
  await assert.rejects(() => internalGroup('app1', 'group1', fixture(false)), /internal group/);
  await assert.rejects(() => internalGroup('app1', 'group1', fixture(true, 'wrong')), /internal group/);
  await assert.rejects(() => internalGroup('app1', 'group1', fixture(true, 'app1', [])), /no tester/);
  await assert.rejects(() => internalGroup('app1', '../external', fixture()), /existing ASC_INTERNAL_GROUP_ID/);
});

test('paginated read fails closed on repeated next links', async () => {
  await assert.rejects(() => list('/v1/builds', async () => ({data: [], links: {next: '/v1/builds'}})), /pagination/);
});
