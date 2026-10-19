#!/usr/bin/env node
// Narrow ASC adapter used only by testflight-ios.mjs in CI. No provisioning,
// key creation, tester invitations, external beta review, or App Store writes.
import {sign} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

const origin = 'https://api.appstoreconnect.apple.com';
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');

export async function api(path, method = 'GET', body) {
  const url = new URL(path, origin);
  if (url.origin !== origin || !url.pathname.startsWith('/v1/')) throw new Error('Unexpected ASC endpoint.');
  const issuer = process.env.ASC_ISSUER_ID || process.env.ASC_API_ISSUER_ID;
  const keyID = process.env.ASC_KEY_ID || process.env.ASC_API_KEY_ID;
  const keyPath = process.env.ASC_PRIVATE_KEY_PATH || process.env.ASC_API_KEY_PATH;
  if (!issuer || !keyID || !keyPath) throw new Error('Missing explicit ASC API credentials.');
  const now = Math.floor(Date.now() / 1000);
  const payload = `${encode({alg: 'ES256', kid: keyID, typ: 'JWT'})}.${encode({iss: issuer, iat: now - 10, exp: now + 300, aud: 'appstoreconnect-v1'})}`;
  const signature = sign('sha256', Buffer.from(payload), {key: readFileSync(keyPath), dsaEncoding: 'ieee-p1363'}).toString('base64url');
  const response = await fetch(url, {method, headers: {
    Authorization: `Bearer ${payload}.${signature}`, 'Content-Type': 'application/json',
  }, body: body ? JSON.stringify(body) : undefined, redirect: 'error', signal: AbortSignal.timeout(30000)});
  if (!response.ok) throw new Error(`ASC ${method} request failed (HTTP ${response.status}); endpoint identifiers and response withheld.`);
  return response.status === 204 ? {} : response.json();
}

export async function list(path, request = api) {
  const data = [];
  const seen = new Set();
  while (path) {
    if (seen.has(path) || seen.size >= 100) throw new Error('Unexpected ASC pagination.');
    seen.add(path);
    const response = await request(path);
    if (!Array.isArray(response.data)) throw new Error('ASC list response has no data array.');
    data.push(...response.data);
    path = response.links?.next;
  }
  return data;
}

export async function builds(appID, version, buildNumber, request = api) {
  const versions = await list('/v1/preReleaseVersions?' + new URLSearchParams({
    'filter[app]': appID, 'filter[version]': version, 'filter[platform]': 'IOS', limit: '200',
  }), request);
  const exact = versions.filter(item => item.attributes?.version === version && item.attributes?.platform === 'IOS');
  if (exact.length > 1) throw new Error('Ambiguous iOS pre-release version.');
  if (!exact.length) return [];
  const result = await list('/v1/builds?' + new URLSearchParams({
    'filter[app]': appID, 'filter[preReleaseVersion]': exact[0].id, 'filter[version]': String(buildNumber), limit: '200',
  }), request);
  if (result.some(item => String(item.attributes?.version) !== String(buildNumber))) throw new Error('ASC returned a different build number.');
  return result;
}

export async function assertBuildUnused(appID, version, buildNumber, request = api) {
  if ((await builds(appID, version, buildNumber, request)).length) {
    throw new Error('Build already exists: inspect Apple state, do not upload a duplicate.');
  }
  const uploads = await list(`/v1/apps/${encodeURIComponent(appID)}/buildUploads?` + new URLSearchParams({
    'filter[cfBundleShortVersionString]': version,
    'filter[cfBundleVersion]': String(buildNumber), 'filter[platform]': 'IOS',
    'fields[buildUploads]': 'cfBundleShortVersionString,cfBundleVersion,platform,state', limit: '200',
  }), request);
  if (uploads.some(item => item.attributes?.cfBundleShortVersionString !== version ||
      item.attributes?.cfBundleVersion !== String(buildNumber) || item.attributes?.platform !== 'IOS')) {
    throw new Error('ASC returned an unexpected upload identity; no upload performed.');
  }
  // Accepted uploads can exist before a processed build appears. Even FAILED or
  // unknown upload states require inspection; never infer permission to retry.
  if (uploads.length) throw new Error('Upload record already exists: inspect Apple state and use a new build number; no automatic upload retry.');
}

export async function internalGroup(appID, groupID, request = api) {
  if (!/^[a-zA-Z0-9-]+$/.test(groupID || '')) throw new Error('Set an existing ASC_INTERNAL_GROUP_ID.');
  const group = (await request(`/v1/betaGroups/${groupID}`)).data;
  const app = (await request(`/v1/betaGroups/${groupID}/relationships/app`)).data;
  if (group?.attributes?.isInternalGroup !== true || app?.id !== appID) throw new Error('Group must be an existing internal group for the selected app.');
  const testers = (await request(`/v1/betaGroups/${groupID}/relationships/betaTesters?limit=1`)).data;
  if (!Array.isArray(testers) || !testers.length) throw new Error('Existing internal group has no tester; no invitations are created by CI.');
  return group;
}

async function main(args) {
  const [resource, operation, ...rest] = args;
  const flags = {};
  for (let index = 0; index < rest.length; index += 2) flags[rest[index]] = rest[index + 1];
  if (resource === 'apps' && operation === 'list') {
    const data = await list('/v1/apps?' + new URLSearchParams({'filter[bundleId]': flags['--bundle-id'], limit: '200'}));
    console.log(JSON.stringify({data}));
  } else if (resource === 'builds' && operation === 'list') {
    console.log(JSON.stringify({data: await builds(flags['--app'], flags['--version'], flags['--build-number'])}));
  } else if (resource === 'builds' && operation === 'upload') {
    if (process.env.CI_UPLOAD_AUTHORIZED !== 'true') throw new Error('Upload requires the protected release workflow.');
    const prepared = JSON.parse(readFileSync('.build/TestFlight/prepared.json', 'utf8'));
    if (prepared.appID !== flags['--app'] || !flags['--ipa'] || resolve(prepared.ipa) !== resolve(flags['--ipa'])) {
      throw new Error('Upload request differs from the prepared artifact.');
    }
    await assertBuildUnused(prepared.appID, prepared.version, prepared.buildNumber);
    const upload = spawnSync('xcrun', ['altool', '--upload-app', '--type', 'ios', '--file', flags['--ipa'],
      '--apiKey', process.env.ASC_KEY_ID, '--apiIssuer', process.env.ASC_ISSUER_ID, '--output-format', 'json'], {stdio: 'pipe', encoding: 'utf8', timeout: 900000});
    if (upload.status !== 0) throw new Error('Apple upload failed or timed out; inspect ASC before retrying. Output withheld to protect account details.');
    console.log('Apple accepted the upload request; processing and group availability are verified next.');
  } else {
    throw new Error('Unsupported CI ASC command; this adapter intentionally has no account/provisioning commands.');
  }
}

if (process.argv[1] && (import.meta.url === pathToFileURL(process.argv[1]).href || process.argv[1].endsWith('/asc'))) {
  main(process.argv.slice(2)).catch(error => {console.error(error.message); process.exitCode = 1;});
}
