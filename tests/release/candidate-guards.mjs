import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const sha256 = value => createHash('sha256').update(value).digest('hex');
const plistDecoder = "import json,plistlib,sys; p=plistlib.loads(sys.stdin.buffer.read()); json.dump({k:p.get(k) for k in ('method','testFlightInternalTestingOnly')},sys.stdout)";
const exportPlist = (internalOnly, method = 'app-store-connect') => `<?xml version="1.0"?>
<plist version="1.0"><dict><key>method</key><string>${method}</string>
<key>testFlightInternalTestingOnly</key><${internalOnly ? 'true' : 'false'}/></dict></plist>`;

// Exercise the actual CLI entry points, but never inherit account credentials or
// execute their tools. Even an incorrectly ordered guard cannot reach the network,
// Xcode, git, signing, or the uploader from this disposable fixture.
function fixture(context, receipt = undefined) {
  // Node canonicalizes import.meta.url, so use the same spelling for argv/cwd
  // (macOS /var aliases /private/var) to exercise ASC's real executable guard.
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'ammo-candidate-guard-')));
  context.after(() => rmSync(root, {recursive: true, force: true}));
  for (const relative of ['scripts/testflight-ios.mjs', 'scripts/testflight-artifact.mjs',
    'scripts/ci/signing-options.mjs', 'scripts/ci/testflight.mjs', 'scripts/ci/asc.mjs']) {
    const destination = join(root, relative);
    mkdirSync(dirname(destination), {recursive: true});
    copyFileSync(join(repository, relative), destination);
  }
  writeFileSync(join(root, 'project.yml'), 'settings:\n  base:\n    MARKETING_VERSION: 0.1.4\n');
  const bin = join(root, 'empty-bin');
  mkdirSync(bin);
  const effectLog = join(root, 'unexpected-effects.log');
  const preload = join(root, 'deny-effects.mjs');
  writeFileSync(preload, `import {appendFileSync} from 'node:fs';
import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
const localSpawnSync = childProcess.spawnSync;
const deny = kind => {
  appendFileSync(process.env.TEST_EFFECT_LOG, kind + '\\n');
  throw new Error('Unexpected side effect: ' + kind);
};
globalThis.fetch = async () => deny('fetch');
for (const name of ['spawnSync', 'spawn', 'execFileSync', 'execFile', 'execSync', 'exec']) {
  childProcess[name] = () => deny('command:' + name);
}
childProcess.spawnSync = (command, args, options) => {
  if (process.env.TEST_ALLOW_PLIST_PARSE === '1' && command === 'python3' &&
      args?.length === 2 && args[0] === '-c' && args[1] === ${JSON.stringify(plistDecoder)} &&
      Buffer.isBuffer(options?.input)) {
    appendFileSync(process.env.TEST_EFFECT_LOG, 'local-plist-parse\\n');
    return localSpawnSync('/usr/bin/python3', ['-I', ...args], {
      ...options, env: {PATH: '/usr/bin:/bin', PYTHONNOUSERSITE: '1'},
    });
  }
  return deny('command:spawnSync');
};
syncBuiltinESMExports();
`);
  const env = {PATH: bin, TEST_EFFECT_LOG: effectLog,
    APPLE_TEAM_ID: 'ABCDEFGHIJ', IOS_BUNDLE_ID: 'org.example.ammo', QI_APP_GROUP: 'group.org.example.ammo',
    ASC_INTERNAL_GROUP_ID: 'group1', TESTFLIGHT_ENABLED: 'true', CI_UPLOAD_AUTHORIZED: 'true'};
  let ipa;
  if (receipt !== undefined) {
    const directory = join(root, '.build/TestFlight');
    mkdirSync(join(directory, 'external-candidate'), {recursive: true});
    mkdirSync(join(root, '.build/ci'), {recursive: true});
    ipa = join(directory, 'export/AmmoPhone.ipa');
    mkdirSync(dirname(ipa), {recursive: true});
    const artifact = 'synthetic artifact: never an installable IPA';
    const screenshot = 'synthetic screenshot: no device was operated';
    const options = exportPlist(true);
    const prepared = {commit: 'a'.repeat(40), appID: '123', version: '0.1.4', buildNumber: '18',
      ipa, sha256: sha256(artifact), exportOptionsSha256: sha256(options), ...receipt};
    writeFileSync(ipa, artifact);
    writeFileSync(join(directory, 'ExportOptions.plist'), options);
    writeFileSync(join(directory, 'prepared.json'), JSON.stringify(prepared));
    writeFileSync(join(directory, 'external-candidate/prepared.json'), JSON.stringify(prepared));
    writeFileSync(join(root, '.build/ci/release-ref.json'), JSON.stringify({
      commit: prepared.commit, version: prepared.version, buildNumber: prepared.buildNumber,
      tag: 'testflight/ios/v0.1.4-b18', tagObject: 'b'.repeat(40),
    }));
    writeFileSync(join(root, '.build/ci/ios-simulator-smoke.png'), screenshot);
    writeFileSync(join(root, '.build/ci/simulator-smoke.json'), JSON.stringify({
      commit: prepared.commit, launchSucceeded: true, screenshotSha256: sha256(screenshot),
    }));
  }
  return {
    root, ipa,
    run(script, args, extra = {}) {
      return spawnSync(process.execPath, ['--import', pathToFileURL(preload).href, join(root, script), ...args], {
        cwd: root, env: {...env, ...extra}, encoding: 'utf8', timeout: 5000,
      });
    },
    effects() { return existsSync(effectLog) ? readFileSync(effectLog, 'utf8').trim().split('\n') : []; },
  };
}

function rejectedBeforeEffects(f, result, allowedEffects = []) {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.notEqual(result.status, 0, result.stdout);
  assert.match(result.stderr, /candidate|prepare.only|internal.only|internal.*(?:artifact|receipt|release|SHA.256)/i);
  assert.doesNotMatch(result.stderr, /ENOENT|Missing.*credential|Unexpected side effect/i);
  assert.deepEqual(f.effects(), allowedEffects, result.stderr);
  assert.equal(existsSync(join(f.root, '.release')), false, 'No release gates may be manufactured');
}

test('candidate dry-run isolates every default artifact path without commands, ASC or filesystem outputs', context => {
  const f = fixture(context);
  const result = f.run('scripts/testflight-ios.mjs', ['--dry-run'], {IOS_TESTFLIGHT_MODE: 'external-candidate'});
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  const config = JSON.parse(result.stdout);
  const candidate = join(f.root, '.build/TestFlight/external-candidate');
  assert.equal(config.mode, 'external-candidate');
  assert.equal(config.expectedAudience, 'APP_STORE_ELIGIBLE');
  assert.equal(config.exportSettings.testFlightInternalTestingOnly, false);
  assert.equal(config.exportSettings.method, 'app-store-connect');
  assert.equal(config.archivePath, join(candidate, 'AmmoPhone.xcarchive'));
  assert.equal(config.exportPath, join(candidate, 'export'));
  assert.equal(config.exportOptions, join(candidate, 'ExportOptions.plist'));
  assert.equal(config.receiptPath, join(candidate, 'prepared.json'));
  assert.deepEqual(f.effects(), []);
  assert.equal(existsSync(join(f.root, '.build')), false, 'Dry-run must not create archive, export, receipt or options');
});

for (const [key, value] of Object.entries({
  IOS_ARCHIVE_PATH: '.build/TestFlight/AmmoPhone.xcarchive',
  IOS_EXPORT_PATH: '.build/TestFlight/external-candidate/../export',
  IOS_EXPORT_OPTIONS_PLIST: '.build/TestFlight/ExportOptions.plist',
})) {
  test(`candidate dry-run refuses ${key} escaping into internal artifact storage`, context => {
    const f = fixture(context);
    rejectedBeforeEffects(f, f.run('scripts/testflight-ios.mjs', ['--dry-run'], {
      IOS_TESTFLIGHT_MODE: 'external-candidate', [key]: value,
    }));
    assert.equal(existsSync(join(f.root, '.build')), false);
  });
}

test('candidate namespace cannot be a symlink alias of internal artifacts', context => {
  const f = fixture(context);
  const internal = join(f.root, '.build/TestFlight');
  mkdirSync(internal, {recursive: true});
  const sentinel = join(internal, 'prepared.json');
  writeFileSync(sentinel, 'existing internal artifact must remain untouched');
  symlinkSync(internal, join(internal, 'external-candidate'), 'dir');
  rejectedBeforeEffects(f, f.run('scripts/testflight-ios.mjs', ['--dry-run'], {IOS_TESTFLIGHT_MODE: 'external-candidate'}));
  assert.equal(readFileSync(sentinel, 'utf8'), 'existing internal artifact must remain untouched');
});

const scenarios = [
  {name: 'candidate configuration with an internal receipt', mode: 'external-candidate', receipt: {mode: 'internal', internalOnly: true}},
  {name: 'internal configuration with a candidate receipt', mode: 'internal', receipt: {mode: 'external-candidate', internalOnly: false}},
  {name: 'candidate receipt relabelled internal-only', mode: 'internal', receipt: {mode: 'external-candidate', internalOnly: true}},
];
const entryPoints = [
  {name: 'local uploader', script: 'scripts/testflight-ios.mjs', args: () => ['--upload']},
  {name: 'CI upload gates', script: 'scripts/ci/testflight.mjs', args: () => ['upload']},
  {name: 'CI readback and group linker', script: 'scripts/ci/testflight.mjs', args: () => ['readback']},
  {name: 'final ASC upload adapter', script: 'scripts/ci/asc.mjs', args: f => ['builds', 'upload', '--app', '123', '--ipa', f.ipa]},
];
for (const entry of entryPoints) {
  for (const scenario of scenarios) {
    test(`${entry.name} rejects ${scenario.name} before credentials, commands or API calls`, context => {
      const f = fixture(context, scenario.receipt);
      rejectedBeforeEffects(f, f.run(entry.script, entry.args(f), {IOS_TESTFLIGHT_MODE: scenario.mode}));
    });
  }
}

const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));
const writeJSON = (path, value) => writeFileSync(path, JSON.stringify(value));
function editJSON(path, edit) {
  const value = readJSON(path);
  edit(value);
  writeJSON(path, value);
  return value;
}

// Relabel both receipt fields, then exercise the actual CI commands. These cases
// would get past a label-only guard; file binding must stop them before ASC.
const artifactTampering = [
  {name: 'a candidate IPA path after both labels were changed', change(f, receipt) {
    const candidateIPA = join(f.root, '.build/TestFlight/external-candidate/export/AmmoPhone.ipa');
    mkdirSync(dirname(candidateIPA), {recursive: true});
    copyFileSync(f.ipa, candidateIPA);
    receipt.ipa = candidateIPA;
  }},
  {name: 'a symbolic-link IPA', change(f) {
    const target = join(f.root, 'synthetic-ipa.bin');
    copyFileSync(f.ipa, target);
    rmSync(f.ipa);
    symlinkSync(target, f.ipa);
  }},
  {name: 'an export directory aliasing candidate storage', change(f) {
    const target = join(f.root, '.build/TestFlight/external-candidate/export');
    mkdirSync(target);
    copyFileSync(f.ipa, join(target, 'AmmoPhone.ipa'));
    rmSync(dirname(f.ipa), {recursive: true});
    symlinkSync(target, dirname(f.ipa), 'dir');
  }},
  {name: 'symbolic-link export options', change(f) {
    const path = join(f.root, '.build/TestFlight/ExportOptions.plist');
    const target = join(f.root, 'synthetic-export.plist');
    copyFileSync(path, target);
    rmSync(path);
    symlinkSync(target, path);
  }},
  {name: 'an incorrect IPA SHA-256', change(_f, receipt) { receipt.sha256 = '0'.repeat(64); }},
  {name: 'an incorrect export options SHA-256', change(_f, receipt) { receipt.exportOptionsSha256 = '0'.repeat(64); }},
  {name: 'correctly hashed external export options relabelled internal', parse: true, change(f, receipt) {
    const options = exportPlist(false);
    writeFileSync(join(f.root, '.build/TestFlight/ExportOptions.plist'), options);
    receipt.exportOptionsSha256 = sha256(options);
  }},
  {name: 'correctly hashed non-App-Store export options', parse: true, change(f, receipt) {
    const options = exportPlist(true, 'development');
    writeFileSync(join(f.root, '.build/TestFlight/ExportOptions.plist'), options);
    receipt.exportOptionsSha256 = sha256(options);
  }},
];
for (const entry of entryPoints.slice(1)) {
  for (const scenario of artifactTampering) {
    test(`${entry.name} rejects ${scenario.name} before fetch, altool or group writes`, context => {
      const f = fixture(context, {mode: 'internal', internalOnly: true});
      const prepared = editJSON(join(f.root, '.build/TestFlight/prepared.json'), receipt => scenario.change(f, receipt));
      f.ipa = prepared.ipa; // Keep final adapter arguments consistent with the forged receipt.
      const result = f.run(entry.script, entry.args(f), {
        IOS_TESTFLIGHT_MODE: 'internal', TEST_ALLOW_PLIST_PARSE: scenario.parse ? '1' : '0',
      });
      rejectedBeforeEffects(f, result, scenario.parse ? ['local-plist-parse'] : []);
    });
  }
}

for (const receipt of [{mode: 'internal', internalOnly: true}, {internalOnly: true}]) {
  test(`artifact verification accepts a valid ${receipt.mode ? 'current' : 'historical'} internal receipt using only local plist parsing`, context => {
    const f = fixture(context, receipt);
    writeFileSync(join(f.root, 'verify-internal.mjs'), `
      import {readFileSync} from 'node:fs';
      import {verifyInternalArtifact} from './scripts/ci/signing-options.mjs';
      verifyInternalArtifact(JSON.parse(readFileSync('.build/TestFlight/prepared.json', 'utf8')));
    `);
    const result = f.run('verify-internal.mjs', [], {IOS_TESTFLIGHT_MODE: 'internal', TEST_ALLOW_PLIST_PARSE: '1'});
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(f.effects(), ['local-plist-parse']);
  });
}

function workflowRun(name) {
  const workflow = readFileSync(join(repository, '.github/workflows/testflight-internal.yml'), 'utf8').split('\n');
  const step = workflow.findIndex(line => line.trim() === `- name: ${name}`);
  assert.ok(step >= 0, `Locate actual workflow step: ${name}`);
  const run = workflow.findIndex((line, index) => index > step && /^        run: \|\s*$/.test(line));
  assert.ok(run > step);
  const script = [];
  for (const line of workflow.slice(run + 1)) {
    if (line.trim() && !line.startsWith('          ')) break;
    script.push(line.slice(10));
  }
  return script;
}

function candidateReceiptFixture(context) {
  const f = fixture(context);
  const candidate = join(f.root, '.build/TestFlight/external-candidate');
  f.ipa = join(candidate, 'export/AmmoPhone.ipa');
  f.options = join(candidate, 'ExportOptions.plist');
  f.preparedPath = join(candidate, 'prepared.json');
  f.receiptPath = join(f.root, '.build/ci/testflight-candidate-receipt.json');
  mkdirSync(dirname(f.ipa), {recursive: true});
  mkdirSync(dirname(f.receiptPath), {recursive: true});
  const artifact = 'synthetic candidate: never an installable IPA';
  const options = exportPlist(false);
  writeFileSync(f.ipa, artifact);
  writeFileSync(f.options, options);
  const identity = {commit: 'a'.repeat(40), version: '0.1.4', buildNumber: '18'};
  writeJSON(f.preparedPath, {mode: 'external-candidate', internalOnly: false, ...identity,
    ipa: f.ipa, sha256: sha256(artifact), exportOptionsSha256: sha256(options)});
  writeJSON(f.receiptPath, {mode: 'external-candidate', stage: 'prepared-only', ...identity,
    expectedAudience: 'APP_STORE_ELIGIBLE', ipaSha256: sha256(artifact), exportOptionsSha256: sha256(options)});
  const run = workflowRun('Verify external candidate receipt and artifact binding');
  assert.equal(run[0], "node --input-type=module <<'NODE'");
  const end = run.indexOf('NODE');
  assert.ok(end > 1, 'Extract the actual trusted workflow Node heredoc');
  writeFileSync(join(f.root, 'verify-candidate.mjs'), run.slice(1, end).join('\n'));
  f.verify = (extra = {}) => f.run('verify-candidate.mjs', [], {
    IOS_TESTFLIGHT_MODE: 'external-candidate', RELEASE_COMMIT: identity.commit,
    RELEASE_VERSION: identity.version, IOS_BUILD_NUMBER: identity.buildNumber,
    TEST_ALLOW_PLIST_PARSE: '1', ...extra,
  });
  return f;
}

test('actual trusted workflow accepts a complete candidate receipt bound to selector and local files', context => {
  const f = candidateReceiptFixture(context);
  const result = f.verify();
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Verified candidate preparation only; no Apple upload or review occurred/);
  assert.deepEqual(f.effects(), ['local-plist-parse']);
});

const candidateTampering = [
  {name: 'an old tag producing only an internal receipt', change(f) {
    const prepared = readJSON(f.preparedPath);
    writeJSON(join(f.root, '.build/TestFlight/prepared.json'), {...prepared, mode: 'internal', internalOnly: true});
    rmSync(f.preparedPath);
    rmSync(f.receiptPath);
  }},
  {name: 'a missing public receipt', change(f) { rmSync(f.receiptPath); }},
  {name: 'a missing private receipt', change(f) { rmSync(f.preparedPath); }},
  ...Object.entries({mode: 'internal', internalOnly: true, commit: 'b'.repeat(40), version: '0.1.5', buildNumber: '19'})
    .map(([key, value]) => ({name: `a mismatched private ${key}`, change(f) { editJSON(f.preparedPath, r => { r[key] = value; }); }})),
  ...Object.entries({mode: 'internal', stage: 'uploaded', commit: 'b'.repeat(40), version: '0.1.5', buildNumber: '19',
    expectedAudience: 'INTERNAL_ONLY', ipaSha256: '0'.repeat(64), exportOptionsSha256: '0'.repeat(64)})
    .map(([key, value]) => ({name: `a mismatched public ${key}`, parse: true, change(f) { editJSON(f.receiptPath, r => { r[key] = value; }); }})),
  {name: 'a missing public identity field', parse: true, change(f) { editJSON(f.receiptPath, r => { delete r.commit; }); }},
  {name: 'unexpected public receipt fields', parse: true, change(f) { editJSON(f.receiptPath, r => { r.appID = 'synthetic-private-field'; }); }},
  {name: 'IPA content changed after preparation', change(f) { writeFileSync(f.ipa, 'different synthetic candidate'); }},
  {name: 'export options changed after preparation', change(f) { writeFileSync(f.options, exportPlist(true)); }},
  {name: 'a candidate IPA path pointing at internal storage', change(f) {
    const internalIPA = join(f.root, '.build/TestFlight/export/AmmoPhone.ipa');
    mkdirSync(dirname(internalIPA));
    copyFileSync(f.ipa, internalIPA);
    editJSON(f.preparedPath, r => { r.ipa = internalIPA; });
  }},
  {name: 'a missing IPA', change(f) { rmSync(f.ipa); }},
  {name: 'multiple IPA files', change(f) { copyFileSync(f.ipa, join(dirname(f.ipa), 'Other.ipa')); }},
  {name: 'an IPA directory', change(f) { rmSync(f.ipa); mkdirSync(f.ipa); }},
  ...['ipa', 'options', 'preparedPath', 'receiptPath'].map(key => ({name: `a symlink for ${key}`, change(f) {
    const target = join(f.root, `synthetic-${key}.bin`);
    copyFileSync(f[key], target);
    rmSync(f[key]);
    symlinkSync(target, f[key]);
  }})),
  ...[
    ['internal-only export options with matching hashes', exportPlist(true)],
    ['non-App-Store export options with matching hashes', exportPlist(false, 'development')],
    ['invalid plist contents with matching hashes', 'synthetic malformed plist'],
  ].map(([name, options]) => ({name, parse: true, change(f) {
    writeFileSync(f.options, options);
    editJSON(f.preparedPath, r => { r.exportOptionsSha256 = sha256(options); });
    editJSON(f.receiptPath, r => { r.exportOptionsSha256 = sha256(options); });
  }})),
];
for (const scenario of candidateTampering) {
  test(`actual trusted workflow refuses ${scenario.name} without network or upload tools`, context => {
    const f = candidateReceiptFixture(context);
    scenario.change(f);
    const result = f.verify();
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0, result.stdout);
    assert.doesNotMatch(result.stderr, /Unexpected side effect|Missing.*credential/);
    assert.deepEqual(f.effects(), scenario.parse ? ['local-plist-parse'] : [], result.stderr);
  });
}

test('actual workflow selector keeps internal publishing and rejects candidate publishing before approval', context => {
  const f = fixture(context);
  const workflow = readFileSync(join(repository, '.github/workflows/testflight-internal.yml'), 'utf8').split('\n');
  const inputDefault = name => {
    const start = workflow.indexOf(`      ${name}:`);
    assert.ok(start >= 0, `Missing workflow input ${name}`);
    for (const line of workflow.slice(start + 1)) {
      if (line.trim() && !line.startsWith('        ')) break;
      const match = line.match(/^        default: (.+)$/);
      if (match) return match[1];
    }
  };
  assert.equal(inputDefault('distribution'), 'internal');
  assert.equal(inputDefault('publish'), 'false');
  const step = workflow.findIndex(line => line.includes('- name: Reject unsupported release requests before credentials or environment approval'));
  assert.ok(step >= 0, 'Locate the actual unprivileged selector guard');
  const run = workflow.findIndex((line, index) => index > step && /^        run: \|\s*$/.test(line));
  assert.ok(run > step);
  const script = [];
  for (const line of workflow.slice(run + 1)) {
    if (line.trim() && !line.startsWith('          ')) break;
    script.push(line.slice(10));
  }
  assert.ok(script.join('\n').trim());
  const matrix = [
    ['ios', 'internal', 'false', true], ['ios', 'internal', 'true', true],
    ['ios', 'external-candidate', 'false', true], ['ios', 'external-candidate', 'true', false],
    ['ios', 'external-candidate', '', false], ['ios', 'external-candidate', 'false\n', false],
    ['ios', 'external', 'false', false], ['ios', '', 'false', false],
    ['macos', 'internal', 'false', false], ['macos', 'external-candidate', 'false', false],
  ];
  for (const [platform, distribution, publish, allowed] of matrix) {
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script.join('\n')], {
      cwd: f.root, env: {PATH: join(f.root, 'empty-bin'), PLATFORM: platform, DISTRIBUTION: distribution, PUBLISH: publish},
      encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status === 0, allowed, JSON.stringify({platform, distribution, publish, stderr: result.stderr}));
  }
  assert.equal(existsSync(join(f.root, '.build')), false);
});
