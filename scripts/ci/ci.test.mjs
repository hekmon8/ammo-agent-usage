import test from 'node:test';
import assert from 'node:assert/strict';
import {assertInternalRelease, distributionMode, exportOptions} from './signing-options.mjs';
import {parseTag, protectsTag, successfulChecks, verifyReleaseEnvironment} from './release-ref.mjs';
import {assertBuildUnused, builds, internalGroup, list} from './asc.mjs';

test('distribution mode defaults to internal and requires an explicit candidate selection', () => {
  assert.equal(distributionMode({}), 'internal');
  assert.equal(distributionMode({IOS_TESTFLIGHT_MODE: 'internal'}), 'internal');
  assert.equal(distributionMode({IOS_TESTFLIGHT_INTERNAL_ONLY: '1'}), 'internal');
  assert.equal(distributionMode({IOS_TESTFLIGHT_MODE: 'external-candidate'}), 'external-candidate');
  for (const mode of ['', 'external', 'EXTERNAL', 'app-store', ' internal', 'external-candidate\n']) {
    assert.throws(() => distributionMode({IOS_TESTFLIGHT_MODE: mode}), `invalid mode ${JSON.stringify(mode)}`);
  }
  for (const legacy of ['0', '', 'true', 'false']) {
    assert.throws(() => distributionMode({IOS_TESTFLIGHT_INTERNAL_ONLY: legacy}), `legacy flag ${JSON.stringify(legacy)}`);
  }
  for (const legacy of ['0', '1', '']) {
    assert.throws(() => distributionMode({IOS_TESTFLIGHT_MODE: 'external-candidate', IOS_TESTFLIGHT_INTERNAL_ONLY: legacy}));
  }
});

test('internal release guard binds both configured mode and prepared receipt without changing either', () => {
  const historical = {internalOnly: true};
  const current = {mode: 'internal', internalOnly: true};
  assert.doesNotThrow(() => assertInternalRelease(undefined, {}));
  assert.doesNotThrow(() => assertInternalRelease(historical, {}));
  assert.doesNotThrow(() => assertInternalRelease(current, {IOS_TESTFLIGHT_MODE: 'internal'}));
  assert.deepEqual(historical, {internalOnly: true});
  assert.deepEqual(current, {mode: 'internal', internalOnly: true});
  for (const receipt of [undefined, historical, current, {mode: 'external-candidate', internalOnly: false}]) {
    assert.throws(() => assertInternalRelease(receipt, {IOS_TESTFLIGHT_MODE: 'external-candidate'}));
  }
  for (const receipt of [{}, {internalOnly: false}, {internalOnly: 'true'},
    {mode: 'external-candidate', internalOnly: false}, {mode: 'external-candidate', internalOnly: true},
    {mode: '', internalOnly: true}, {mode: 'unknown', internalOnly: true}]) {
    assert.throws(() => assertInternalRelease(receipt, {}));
  }
});

test('manual export uses exactly the app and widget profiles and retains internal-only', () => {
  const defaults = exportOptions('ABCDEFGHIJ', 'org.example.ammo', {});
  assert.equal(defaults.signingStyle, 'automatic');
  assert.equal(defaults.testFlightInternalTestingOnly, true);
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

test('candidate export changes audience only and keeps exact distribution signing profiles', () => {
  const profiles = {'org.example.ammo': 'App Store App', 'org.example.ammo.widgets': 'App Store Widget'};
  const env = {IOS_SIGNING_STYLE: 'manual', IOS_PROVISIONING_PROFILES: JSON.stringify(profiles)};
  const internal = exportOptions('ABCDEFGHIJ', 'org.example.ammo', env);
  const candidateEnv = {...env, IOS_TESTFLIGHT_MODE: 'external-candidate'};
  const candidate = exportOptions('ABCDEFGHIJ', 'org.example.ammo', candidateEnv);
  assert.deepEqual(candidate, {...internal, testFlightInternalTestingOnly: false});
  assert.equal(candidate.method, 'app-store-connect');
  assert.equal(candidate.signingCertificate, 'Apple Distribution');
  for (const invalid of [{}, {'org.example.ammo': 'App'}, {...profiles, other: 'Other'},
    {...profiles, 'org.example.ammo': ''}, {...profiles, 'org.example.ammo.widgets': 'unsafe\nname'}]) {
    assert.throws(() => exportOptions('ABCDEFGHIJ', 'org.example.ammo', {
      ...candidateEnv, IOS_PROVISIONING_PROFILES: JSON.stringify(invalid),
    }), /exact app and widget/);
  }
  assert.throws(() => exportOptions('ABCDEFGHIJ', 'org.example.ammo', {
    ...candidateEnv, IOS_SIGNING_STYLE: 'external',
  }), /explicit manual/);
});

test('release selector rejects ambiguous tags and build-number injection', () => {
  assert.deepEqual(parseTag('testflight/ios/v0.1.4-b11'), {version: '0.1.4', buildNumber: '11'});
  for (const value of ['main', 'v0.1.4', 'testflight/ios/v0.1.4-b0', 'testflight/macos/v0.1.4-b11', 'testflight/ios/v0.1.4-b1\nrun']) {
    assert.throws(() => parseTag(value));
  }
});

test('tag rules must actively restrict creation, update and deletion without exclusions', () => {
  const ruleset = {target: 'tag', enforcement: 'active', conditions: {ref_name: {include: ['refs/tags/testflight/ios/**'], exclude: []}}, rules: ['creation', 'update', 'deletion'].map(type => ({type}))};
  assert.equal(protectsTag([ruleset], 'testflight/ios/v0.1.4-b11'), true);
  for (const patch of [{enforcement: 'disabled'}, {target: 'branch'}, {rules: [{type: 'deletion'}]}, {conditions: {ref_name: {include: ['~ALL'], exclude: ['refs/tags/testflight/**']}}}]) {
    assert.equal(protectsTag([{...ruleset, ...patch}], 'testflight/ios/v0.1.4-b11'), false);
  }
  const creation = {...ruleset, rules: [{type: 'creation'}]};
  const immutable = {...ruleset, rules: [{type: 'update'}, {type: 'deletion'}]};
  assert.equal(protectsTag([creation, immutable], 'testflight/ios/v0.1.4-b11'), true);
  assert.equal(protectsTag([creation, {...immutable, enforcement: 'disabled'}], 'testflight/ios/v0.1.4-b11'), false);
  assert.equal(protectsTag([creation, {...immutable, conditions: {ref_name: {include: ['refs/tags/other/**']}}}], 'testflight/ios/v0.1.4-b11'), false);
});

test('release environment requires approval without admin bypass and only the default branch', () => {
  const environment = {can_admins_bypass: false,
    protection_rules: [{type: 'required_reviewers', reviewers: [{type: 'User', reviewer: {id: 1}}]}],
    deployment_branch_policy: {custom_branch_policies: true, protected_branches: false}};
  const allowed = [{name: 'main', type: 'branch'}];
  assert.doesNotThrow(() => verifyReleaseEnvironment(environment, allowed, 'main'));
  for (const value of [true, undefined, null]) {
    assert.throws(() => verifyReleaseEnvironment({...environment, can_admins_bypass: value}, allowed, 'main'), /administrator bypass/);
  }
  assert.throws(() => verifyReleaseEnvironment({...environment, protection_rules: []}, allowed, 'main'), /reviewer/);
  for (const branches of [[], [{name: 'main', type: 'tag'}], [{name: '*', type: 'branch'}], [...allowed, {name: 'feature', type: 'branch'}]]) {
    assert.throws(() => verifyReleaseEnvironment(environment, branches, 'main'), /Only the exact default branch/);
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

test('upload gate refuses accepted uploads before a processed build exists, in every state', async () => {
  for (const state of ['AWAITING_UPLOAD', 'PROCESSING', 'FAILED', 'COMPLETE', 'UNKNOWN']) {
    const request = async (path, method) => {
      assert.equal(method, undefined, 'upload readiness uses only reads');
      const url = new URL(path, 'https://api.appstoreconnect.apple.com');
      if (url.pathname === '/v1/preReleaseVersions') return {data: []};
      assert.equal(url.pathname, '/v1/apps/app1/buildUploads');
      assert.equal(url.searchParams.get('filter[platform]'), 'IOS');
      assert.equal(url.searchParams.get('filter[cfBundleShortVersionString]'), '0.1.4');
      assert.equal(url.searchParams.get('filter[cfBundleVersion]'), '16');
      return {data: [{id: 'pending', attributes: {cfBundleShortVersionString: '0.1.4', cfBundleVersion: '16', platform: 'IOS', state: {state}}}]};
    };
    await assert.rejects(() => assertBuildUnused('app1', '0.1.4', '16', request), /Upload record already exists/);
  }
});

test('upload gate requires complete empty processed-build and upload results', async () => {
  await assertBuildUnused('app1', '0.1.4', '16', async () => ({data: []}));
  await assert.rejects(() => assertBuildUnused('app1', '0.1.4', '16', async path => {
    if (path.startsWith('/v1/preReleaseVersions')) return {data: []};
    if (!path.includes('cursor=next')) return {data: [], links: {next: '/v1/apps/app1/buildUploads?cursor=next'}};
    return {data: [{attributes: {cfBundleShortVersionString: '0.1.4', cfBundleVersion: '16', platform: 'IOS'}}]};
  }), /Upload record already exists/);
  await assert.rejects(() => assertBuildUnused('app1', '0.1.4', '16', async path => {
    if (path.startsWith('/v1/preReleaseVersions')) return {data: []};
    throw new Error('synthetic Apple API unavailable');
  }), /API unavailable/);
  await assert.rejects(() => assertBuildUnused('app1', '0.1.4', '16', async path => {
    if (path.startsWith('/v1/preReleaseVersions')) return {data: []};
    return {data: [{attributes: {cfBundleShortVersionString: '0.1.4', cfBundleVersion: '15', platform: 'IOS'}}]};
  }), /unexpected upload identity/);
});

test('upload gate also refuses an existing processed build', async () => {
  await assert.rejects(() => assertBuildUnused('app1', '0.1.4', '16', async path => {
    if (path.startsWith('/v1/preReleaseVersions')) return {data: [{id: 'v', attributes: {version: '0.1.4', platform: 'IOS'}}]};
    assert.ok(path.startsWith('/v1/builds'));
    return {data: [{id: 'existing', attributes: {version: '16'}}]};
  }), /Build already exists/);
});

test('paginated read fails closed on repeated next links', async () => {
  await assert.rejects(() => list('/v1/builds', async () => ({data: [], links: {next: '/v1/builds'}})), /pagination/);
});
