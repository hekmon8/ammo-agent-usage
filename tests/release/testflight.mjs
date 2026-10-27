import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {existsSync, statSync, mkdtempSync, writeFileSync, mkdirSync, symlinkSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {findExportedIPA, validatePreparedIPA} from '../../scripts/testflight-artifact.mjs';

function exportDirectory(context) {
  const directory = mkdtempSync(join(tmpdir(), 'ammo-ipa-test-'));
  context.after(() => rmSync(directory, {recursive:true, force:true}));
  return directory;
}

test('prepare and upload accept Xcode product filenames independent of display name', context => {
  const directory = exportDirectory(context);
  const ipa = join(directory, 'AmmoPhone.ipa');
  writeFileSync(ipa, 'synthetic archive');
  writeFileSync(join(directory, 'ExportOptions.plist'), 'synthetic export metadata');
  assert.equal(findExportedIPA(directory), ipa);
  assert.equal(validatePreparedIPA(directory, ipa), ipa);
  assert.throws(() => validatePreparedIPA(directory, join(directory, 'Ammo.ipa')), /Unexpected prepared IPA path/);
  const otherDirectory = exportDirectory(context);
  const otherIPA = join(otherDirectory, 'AmmoPhone.ipa');
  writeFileSync(otherIPA, 'same filename elsewhere');
  assert.throws(() => validatePreparedIPA(directory, otherIPA), /Unexpected prepared IPA path/);
});

test('missing or ambiguous exports fail closed', context => {
  const directory = exportDirectory(context);
  assert.throws(() => findExportedIPA(directory), /exactly one regular exported IPA/);
  for (const name of ['Ammo.ipa', 'AmmoPhone.ipa']) writeFileSync(join(directory, name), 'synthetic');
  assert.throws(() => findExportedIPA(directory), /exactly one regular exported IPA/);
  assert.throws(() => validatePreparedIPA(directory, join(directory, 'AmmoPhone.ipa')), /exactly one regular exported IPA/);
});

test('IPA directories and symlinks are not accepted as exported artifacts', context => {
  const directory = exportDirectory(context);
  const ipa = join(directory, 'AmmoPhone.ipa');
  mkdirSync(ipa);
  assert.throws(() => findExportedIPA(directory), /exactly one regular exported IPA/);
  rmSync(ipa, {recursive:true});
  const target = join(directory, 'archive.bin');
  writeFileSync(target, 'synthetic');
  symlinkSync(target, ipa);
  assert.throws(() => findExportedIPA(directory), /exactly one regular exported IPA/);
});
test('dry-run needs no ASC or private helper and does not write export options',()=>{
  const path='.build/TestFlight/ExportOptions.plist';
  const before=existsSync(path)?statSync(path).mtimeMs:null;
  const env={PATH:process.env.PATH,APPLE_TEAM_ID:'ABCDEFGHIJ',IOS_BUNDLE_ID:'org.example.ammo',QI_APP_GROUP:'group.org.example.ammo'};
  const result=spawnSync(process.execPath,['scripts/testflight-ios.mjs','--dry-run'],{env,encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  assert.equal(JSON.parse(result.stdout).bundleId,'org.example.ammo');
  assert.equal(JSON.parse(result.stdout).icloudContainer,'iCloud.org.example.ammo');
  assert.equal(JSON.parse(result.stdout).mode,'internal');
  assert.equal(JSON.parse(result.stdout).expectedAudience,'INTERNAL_ONLY');
  assert.equal(JSON.parse(result.stdout).exportSettings.testFlightInternalTestingOnly,true);
  assert.equal(existsSync(path)?statSync(path).mtimeMs:null,before);
});
test('dry-run preserves an explicitly selected existing CloudKit container',()=>{
  const env={PATH:process.env.PATH,APPLE_TEAM_ID:'ABCDEFGHIJ',IOS_BUNDLE_ID:'org.example.ammo',
    QI_APP_GROUP:'group.org.example.ammo',QI_ICLOUD_CONTAINER:'iCloud.org.example.shared'};
  const result=spawnSync(process.execPath,['scripts/testflight-ios.mjs','--dry-run'],{env,encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  assert.equal(JSON.parse(result.stdout).icloudContainer,env.QI_ICLOUD_CONTAINER);
});
test('legacy internal-only flag cannot implicitly enable an external export',()=>{
  const env={PATH:process.env.PATH,APPLE_TEAM_ID:'ABCDEFGHIJ',IOS_BUNDLE_ID:'org.example.ammo',
    QI_APP_GROUP:'group.org.example.ammo',IOS_TESTFLIGHT_INTERNAL_ONLY:'0'};
  const result=spawnSync(process.execPath,['scripts/testflight-ios.mjs','--dry-run'],{env,encoding:'utf8'});
  assert.notEqual(result.status,0);
  assert.match(result.stderr,/legacy|IOS_TESTFLIGHT_INTERNAL_ONLY|internal.only/i);
});
