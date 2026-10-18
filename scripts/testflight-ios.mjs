#!/usr/bin/env node
// Self-contained archive, artifact verification and explicit ASC upload.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { findExportedIPA, validatePreparedIPA } from './testflight-artifact.mjs';
import { exportOptions } from './ci/signing-options.mjs';
const root = resolve(import.meta.dirname, '..');
const project = readFileSync(join(root, 'project.yml'), 'utf8');
const marketingVersion = project.match(/^\s*MARKETING_VERSION:\s*['"]?([0-9]+\.[0-9]+\.[0-9]+)['"]?\s*$/m)?.[1];
if (!marketingVersion) throw new Error('Missing MARKETING_VERSION in project.yml.');
process.chdir(root);
const defaults = {
  IOS_WORKSPACE: 'Ammo.xcworkspace', IOS_SCHEME: 'AmmoPhone',
  IOS_CONFIGURATION: 'Release',
  IOS_VERSION: marketingVersion, IOS_TESTFLIGHT_INTERNAL_ONLY: '1',
  IOS_TESTFLIGHT_OUTPUT_ROOT: '.build/TestFlight',
  IOS_ARCHIVE_PATH: '.build/TestFlight/AmmoPhone.xcarchive',
  IOS_EXPORT_PATH: '.build/TestFlight/export',
  IOS_EXPORT_OPTIONS_PLIST: '.build/TestFlight/ExportOptions.plist',
};
for (const [key,value] of Object.entries(defaults)) process.env[key] ||= value;
const mode = process.argv[2];
if (!['--dry-run','--prepare','--upload'].includes(mode)) throw new Error('Choose --dry-run, --prepare, or --upload.');
if (process.env.IOS_TESTFLIGHT_INTERNAL_ONLY !== '1') throw new Error('This script only exports and uploads internal TestFlight builds.');
for (const key of ['APPLE_TEAM_ID', 'IOS_BUNDLE_ID', 'QI_APP_GROUP']) {
  if (!process.env[key]) throw new Error(`Set ${key} explicitly for your own signing identity.`);
}
if (!/^[A-Z0-9]{10}$/.test(process.env.APPLE_TEAM_ID)) throw new Error('Invalid Apple Team ID.');
const config = {
  bundleId: process.env.IOS_BUNDLE_ID, teamId: process.env.APPLE_TEAM_ID,
  version: marketingVersion, scheme: process.env.IOS_SCHEME,
  archivePath: resolve(root, process.env.IOS_ARCHIVE_PATH),
  exportPath: resolve(root, process.env.IOS_EXPORT_PATH),
  exportOptions: resolve(root, process.env.IOS_EXPORT_OPTIONS_PLIST),
};
// Dry run is local, performs no ASC calls and creates no output files.
if (mode === '--dry-run') { console.log(JSON.stringify(config, null, 2)); process.exit(0); }
function command(exe,args,options={}) {
  const result=spawnSync(exe,args,{stdio:'inherit',...options});
  if(result.status!==0) {
    const detail=String(result.stderr ?? result.stdout ?? '').trim().split('\n').slice(-8).join('\n');
    throw new Error(`${exe} failed (${result.status})${detail ? `:\n${detail}` : ''}`);
  }
  return result.stdout?.trim();
}
function ascEnvironment() {
  const mapping = {
    ASC_KEY_ID: process.env.ASC_API_KEY_ID,
    ASC_ISSUER_ID: process.env.ASC_API_ISSUER_ID,
    ASC_PRIVATE_KEY_PATH: process.env.ASC_API_KEY_PATH,
  };
  for (const [name,value] of Object.entries(mapping)) if (!value) throw new Error(`Missing ASC credential for ${name}.`);
  const env={...process.env,...mapping,ASC_BYPASS_KEYCHAIN:'1'};
  delete env.ASC_PRIVATE_KEY;
  delete env.ASC_PRIVATE_KEY_B64;
  delete env.ASC_PROFILE;
  return env;
}
const ascCommand=(args,options={})=>command('asc',args,{...options,env:ascEnvironment()});
function jsonCommand(exe,args,options={}) {
  const output=exe==='asc'
    ? ascCommand(args,{stdio:'pipe',encoding:'utf8',...options})
    : command(exe,args,{stdio:'pipe',encoding:'utf8',...options});
  try { return JSON.parse(output); }
  catch { throw new Error(`${exe} returned invalid JSON.`); }
}
function listData(value) {
  if(Array.isArray(value)) return value;
  if(Array.isArray(value?.data)) return value.data;
  throw new Error('ASC list response has an unexpected shape.');
}
function resolveStrictAscAppId(bundleID) {
  const apps=listData(jsonCommand('asc',['apps','list','--bundle-id',bundleID,'--output','json']));
  const exact=apps.filter((app)=>(app.bundleId ?? app.attributes?.bundleId)===bundleID);
  if(exact.length!==1 || !(exact[0].id ?? exact[0].appId ?? exact[0].app_id)) throw new Error(`Expected one ASC app for ${bundleID}.`);
  return String(exact[0].id ?? exact[0].appId ?? exact[0].app_id);
}
function parseBuildNumber(value) {
  const build=value?.nextBuildNumber ?? value?.next_build_number ?? value?.buildNumber ?? value?.build_number ?? value;
  if(!/^\d+$/.test(String(build)) || BigInt(build)<=0n) throw new Error('ASC returned an invalid next build number.');
  return String(build);
}
function resolveStrictBuildNumber(appID,version) {
  if(process.env.IOS_BUILD_NUMBER) return parseBuildNumber(process.env.IOS_BUILD_NUMBER);
  return parseBuildNumber(jsonCommand('asc',['builds','next-build-number','--app',appID,'--version',version,'--platform','IOS','--initial-build-number','1','--output','json']));
}
function existingBuilds(appID,version,buildNumber) {
  return listData(jsonCommand('asc',['builds','list','--app',appID,'--version',version,'--build-number',String(buildNumber),'--processing-state','all','--output','json']));
}
const revision=()=>command('git',['rev-parse','HEAD'],{stdio:'pipe',encoding:'utf8'});
const receiptPath=join(root,'.build/TestFlight/prepared.json');
if(mode==='--upload') {
  const receipt=JSON.parse(readFileSync(receiptPath,'utf8'));
  if(receipt.commit!==revision() || command('git',['status','--porcelain'],{stdio:'pipe',encoding:'utf8'})) throw new Error('Prepared source must match clean HEAD.');
  if(receipt.internalOnly!==true || plist(config.exportOptions).testFlightInternalTestingOnly!==true ||
     createHash('sha256').update(readFileSync(config.exportOptions)).digest('hex')!==receipt.exportOptionsSha256) throw new Error('Prepared export is not bound to internal TestFlight options.');
  validatePreparedIPA(config.exportPath, receipt.ipa);
  if(createHash('sha256').update(readFileSync(receipt.ipa)).digest('hex')!==receipt.sha256) throw new Error('Prepared IPA changed.');
  if(receipt.version !== config.version || receipt.appID !== resolveStrictAscAppId(config.bundleId) || !/^\d+$/.test(receipt.buildNumber)) throw new Error('Prepared release identity does not match current configuration.');
  verifyIPA(receipt.ipa,{bundleID:config.bundleId,version:config.version,buildNumber:receipt.buildNumber,teamID:config.teamId,appGroup:process.env.QI_APP_GROUP});
  command('python3',['scripts/release_preflight.py','--profile','internal-testflight',
    '--app-id',receipt.appID,'--bundle-id',config.bundleId,'--version',receipt.version,
    '--build-number',receipt.buildNumber,'--ipa-sha256',receipt.sha256]);
  if(existingBuilds(receipt.appID,receipt.version,receipt.buildNumber).length) throw new Error('Build number already exists; inspect Apple state before any retry.');
  ascCommand(['builds','upload','--app',receipt.appID,'--ipa',receipt.ipa]);
  process.exit(0);
}
if(command('git',['status','--porcelain'],{stdio:'pipe',encoding:'utf8'})) throw new Error('Commit release inputs before archiving.');
const appID=resolveStrictAscAppId(config.bundleId), buildNumber=resolveStrictBuildNumber(appID,config.version);
const commit=revision();
const options = exportOptions(config.teamId, config.bundleId);
command('/bin/mkdir',['-p',config.exportPath]);
writeFileSync(config.exportOptions, JSON.stringify(options), {mode:0o600});
command('/usr/bin/plutil',['-convert','xml1',config.exportOptions]);
command('xcodebuild',['-workspace',process.env.IOS_WORKSPACE,'-scheme',config.scheme,'-configuration',process.env.IOS_CONFIGURATION,'-destination','generic/platform=iOS','-archivePath',config.archivePath,
  `DEVELOPMENT_TEAM=${config.teamId}`,`QI_BUNDLE_PREFIX=${config.bundleId}`,`QI_APP_GROUP=${process.env.QI_APP_GROUP}`,`QI_ICLOUD_CONTAINER=${process.env.QI_ICLOUD_CONTAINER || 'iCloud.'+config.bundleId}`,
  `CURRENT_PROJECT_VERSION=${buildNumber}`,`MARKETING_VERSION=${config.version}`,'archive']);
command('xcodebuild',['-exportArchive','-archivePath',config.archivePath,'-exportPath',config.exportPath,'-exportOptionsPlist',config.exportOptions]);
const ipa=findExportedIPA(config.exportPath);
verifyIPA(ipa,{bundleID:config.bundleId,version:config.version,buildNumber:String(buildNumber),teamID:config.teamId,appGroup:process.env.QI_APP_GROUP});
const receipt={commit,appID,buildNumber:String(buildNumber),version:config.version,ipa,
  sha256:createHash('sha256').update(readFileSync(ipa)).digest('hex'),internalOnly:true,
  exportOptionsSha256:createHash('sha256').update(readFileSync(config.exportOptions)).digest('hex')};
writeFileSync(receiptPath,JSON.stringify(receipt,null,2)+'\n',{mode:0o600});
console.log('Prepared and verified. Upload separately after release gates pass.');

function plist(path) {
  return jsonCommand('/usr/bin/plutil',['-convert','json','-o','-',path]);
}
function findBundle(directory,suffix,expectedID) {
  if(!existsSync(directory)) throw new Error(`Missing bundle directory: ${directory}`);
  const matches=readdirSync(directory).filter((name)=>name.endsWith(suffix)).map((name)=>join(directory,name));
  const exact=matches.filter((path)=>plist(join(path,'Info.plist')).CFBundleIdentifier===expectedID);
  if(exact.length!==1) throw new Error(`Expected one ${expectedID} bundle.`);
  return exact[0];
}
function signedEntitlements(bundle) {
  const xml=command('/usr/bin/codesign',['-d','--entitlements','-','--xml',bundle],{stdio:['ignore','pipe','pipe'],encoding:'utf8'});
  const decoded=spawnSync('/usr/bin/plutil',['-convert','json','-o','-','-'],{input:xml,encoding:'utf8'});
  if(decoded.status!==0) throw new Error(`Invalid signed entitlements for ${bundle}.`);
  return JSON.parse(decoded.stdout);
}
function requireArrayValue(entitlements,key,value,bundle) {
  if(!Array.isArray(entitlements[key]) || !entitlements[key].includes(value)) throw new Error(`Signed ${key} mismatch for ${bundle}.`);
}
function verifyBundle(bundle,{bundleID,version,buildNumber,teamID,appGroup,keychainBundleID}) {
  const info=plist(join(bundle,'Info.plist'));
  if(info.CFBundleIdentifier!==bundleID || info.CFBundleShortVersionString!==version || String(info.CFBundleVersion)!==buildNumber) throw new Error(`Exported identity/version mismatch for ${bundleID}.`);
  const privacy=join(bundle,'PrivacyInfo.xcprivacy');
  if(!existsSync(privacy)) throw new Error(`Missing privacy manifest for ${bundleID}.`);
  plist(privacy);
  command('/usr/bin/codesign',['--verify','--strict',bundle]);
  const entitlements=signedEntitlements(bundle);
  if(entitlements['com.apple.developer.team-identifier']!==teamID) throw new Error(`Signed Team ID mismatch for ${bundleID}.`);
  const applicationID=entitlements['application-identifier'] ?? entitlements['com.apple.application-identifier'];
  const suffix=`.${bundleID}`;
  if(typeof applicationID!=='string' || !applicationID.endsWith(suffix)) throw new Error(`Signed application identifier mismatch for ${bundleID}.`);
  const prefix=applicationID.slice(0,-suffix.length);
  requireArrayValue(entitlements,'com.apple.security.application-groups',appGroup,bundleID);
  requireArrayValue(entitlements,'keychain-access-groups',`${prefix}.${keychainBundleID}.sync`,bundleID);
  return prefix;
}
function verifyIPA(ipa,{bundleID,version,buildNumber,teamID,appGroup}) {
  const directory=mkdtempSync(join(tmpdir(),'quota-island-ipa-'));
  try {
    const entries=command('/usr/bin/unzip',['-Z1',ipa],{stdio:'pipe',encoding:'utf8'}).split('\n');
    if(entries.some(p=>p.startsWith('/') || p.split('/').includes('..') || p.includes('\\'))) throw new Error('Unsafe IPA entry.');
    command('/usr/bin/unzip',['-qq',ipa,'-d',directory]);
    const app=findBundle(join(directory,'Payload'),'.app',bundleID);
    const widgetID=`${bundleID}.widgets`;
    const widget=findBundle(join(app,'PlugIns'),'.appex',widgetID);
    const appPrefix=verifyBundle(app,{bundleID,version,buildNumber,teamID,appGroup,keychainBundleID:bundleID});
    const widgetPrefix=verifyBundle(widget,{bundleID:widgetID,version,buildNumber,teamID,appGroup,keychainBundleID:bundleID});
    if(appPrefix!==widgetPrefix) throw new Error('App and Widget signing prefixes differ.');
    const info=plist(join(app,'Info.plist'));
    const primaryIcon=info.CFBundleIcons?.CFBundlePrimaryIcon;
    if(primaryIcon?.CFBundleIconName!=='AppIcon' || !Array.isArray(primaryIcon.CFBundleIconFiles) || !primaryIcon.CFBundleIconFiles.length || !existsSync(join(app,'Assets.car'))) throw new Error('Exported AppIcon is missing or incomplete.');
  } finally {
    rmSync(directory,{recursive:true,force:true});
  }
}
