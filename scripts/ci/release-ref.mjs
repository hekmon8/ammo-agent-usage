#!/usr/bin/env node
// All checks in this entry point are read-only and run before signing secrets.
import {execFileSync} from 'node:child_process';
import {appendFileSync, mkdirSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

export function parseTag(tag) {
  const match = /^testflight\/ios\/v(\d+\.\d+\.\d+)-b([1-9]\d{0,8})$/.exec(tag);
  if (!match) throw new Error('Use an annotated tag testflight/ios/vVERSION-bBUILD (positive numeric build).');
  return {version: match[1], buildNumber: match[2]};
}

function matches(pattern, ref) {
  if (pattern === '~ALL') return true;
  // Conservative supported patterns for the documented release ruleset.
  return pattern === ref || (pattern === 'refs/tags/testflight/ios/**' && ref.startsWith('refs/tags/testflight/ios/'));
}

export function protectsTag(ruleset, tag) {
  const names = ruleset.conditions?.ref_name;
  return ruleset.target === 'tag' && ruleset.enforcement === 'active' &&
    names?.include?.some(pattern => matches(pattern, 'refs/tags/' + tag)) &&
    !(names?.exclude?.length) &&
    ['creation', 'update', 'deletion'].every(type => ruleset.rules?.some(rule => rule.type === type));
}

export function successfulChecks(run, jobs, commit, branch) {
  return run.head_sha === commit && run.head_branch === branch && run.event === 'push' &&
    run.status === 'completed' && run.conclusion === 'success' &&
    ['contracts-worker', 'ios-simulator', 'macos', 'secrets'].every(name =>
      jobs.some(job => job.name === name && job.status === 'completed' && job.conclusion === 'success'));
}

const git = (...args) => execFileSync('git', args, {encoding: 'utf8'}).trim();

async function github(path) {
  const response = await fetch('https://api.github.com' + path, {
    headers: {Authorization: `Bearer ${process.env.GH_TOKEN}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'},
    signal: AbortSignal.timeout(30000), redirect: 'error',
  });
  if (!response.ok) throw new Error(`Cannot verify GitHub release rules (HTTP ${response.status}).`);
  return response.json();
}

export async function verifyReleaseRef() {
  if (process.env.GITHUB_ACTIONS !== 'true') throw new Error('Release entry point requires GitHub Actions.');
  const tag = process.env.RELEASE_TAG;
  const identity = parseTag(tag);
  const repository = process.env.GITHUB_REPOSITORY;
  const repo = await github(`/repos/${repository}`);
  const branch = repo.default_branch;
  if (process.env.GITHUB_EVENT_NAME !== 'workflow_dispatch' ||
      process.env.GITHUB_REF !== `refs/heads/${branch}` || process.env.GITHUB_REF_PROTECTED !== 'true') {
    throw new Error('Release must be explicitly dispatched from the protected default branch.');
  }
  const environment = await github(`/repos/${repository}/environments/testflight-internal`);
  const reviewers = environment.protection_rules?.find(rule => rule.type === 'required_reviewers');
  if (!reviewers?.reviewers?.length) throw new Error('testflight-internal needs an existing required reviewer.');
  const policy = environment.deployment_branch_policy;
  if (!policy?.custom_branch_policies || policy.protected_branches) throw new Error('testflight-internal must allow only the default branch via a custom deployment policy.');
  const allowed = (await github(`/repos/${repository}/environments/testflight-internal/deployment-branch-policies?per_page=100`)).branch_policies;
  if (allowed?.length !== 1 || allowed[0].name !== branch || allowed[0].type !== 'branch') throw new Error('Only the exact default branch may deploy to testflight-internal; tags/other branches must be excluded.');
  const listed = await github(`/repos/${repository}/rulesets?includes_parents=true&per_page=100`);
  if (listed.length >= 100) throw new Error('Too many rulesets for a bounded release check.');
  let protectedTag = false;
  for (const item of listed.filter(item => item.target === 'tag' && item.enforcement === 'active')) {
    const ruleset = await github(`/repos/${repository}/rulesets/${item.id}`);
    if (protectsTag(ruleset, tag)) protectedTag = true;
  }
  if (!protectedTag) throw new Error('Tag needs active creation/update/deletion restrictions; see docs/github-actions.md.');
  git('fetch', '--no-tags', 'origin', `refs/heads/${branch}:refs/remotes/origin/${branch}`, `refs/tags/${tag}:refs/tags/${tag}`);
  if (git('cat-file', '-t', `refs/tags/${tag}`) !== 'tag') throw new Error('Release tag must be annotated.');
  const tagObject = git('rev-parse', `refs/tags/${tag}`);
  const commit = git('rev-parse', `refs/tags/${tag}^{commit}`);
  git('merge-base', '--is-ancestor', commit, `refs/remotes/origin/${branch}`);
  const runs = await github(`/repos/${repository}/actions/workflows/checks.yml/runs?head_sha=${commit}&event=push&status=success&per_page=100`);
  let checked = false;
  for (const run of runs.workflow_runs ?? []) {
    if (run.head_sha !== commit || run.head_branch !== branch) continue;
    const result = await github(`/repos/${repository}/actions/runs/${run.id}/jobs?filter=latest&per_page=100`);
    if (successfulChecks(run, result.jobs ?? [], commit, branch)) checked = true;
  }
  if (!checked) throw new Error('Exact release commit needs successful Checks on the default branch: contracts-worker, ios-simulator, macos and secrets.');
  const project = git('show', `${commit}:project.yml`);
  const version = project.match(/^\s*MARKETING_VERSION:\s*['"]?([0-9]+\.[0-9]+\.[0-9]+)['"]?\s*$/m)?.[1];
  if (version !== identity.version) throw new Error('Tag marketing version differs from tagged project.yml.');
  const remote = git('ls-remote', 'origin', `refs/tags/${tag}`).split(/\s+/)[0];
  if (remote !== tagObject) throw new Error('Remote tag changed; release stopped.');
  const record = {tag, tagObject, commit, ...identity};
  mkdirSync('.build/ci', {recursive: true});
  writeFileSync('.build/ci/release-ref.json', JSON.stringify(record, null, 2) + '\n');
  if (process.env.GITHUB_OUTPUT) {
    for (const [key, value] of Object.entries(record)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
  }
  console.log(`Verified immutable release selector ${tag} at ${commit}.`);
  return record;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  verifyReleaseRef().catch(error => {console.error(error.message); process.exitCode = 1;});
}
