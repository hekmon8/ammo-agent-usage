import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

const root = new URL("../../..", import.meta.url).pathname;
const wrangler = process.env.WRANGLER_BIN ?? join(root, "workers/lite/node_modules/.bin/wrangler");
const port = 18817;
const writerToken = "synthetic-share-writer-token-00000001";
const otherToken = "synthetic-share-writer-token-00000002";
const fullSyncViewerToken = "synthetic-full-sync-viewer-token-000001";
const inviteSecret = "i".repeat(43);
const secondInviteSecret = "j".repeat(43);
const expiredInviteSecret = "k".repeat(43);
const expiredClaimToken = "synthetic-expired-claim-token-0000001";
const oldClaimToken = "synthetic-old-claim-token-00000000001";
const persistentViewerToken = "synthetic-persistent-viewer-token-0001";
const hash = async (text) => Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))).toString("hex");

function command(args, state) {
  // Allocate the inspector socket atomically, independently of parallel suites.
  if (args[0] === "dev") args = [...args, "--inspector-port", "0"];
  const child = spawn(wrangler, args, { cwd: root, env: { ...process.env, WRANGLER_LOG_PATH: join(state, "wrangler.log"), WRANGLER_REGISTRY_PATH: join(state, "registry") }, stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  const append = (chunk) => { output = (output + chunk.toString()).slice(-12_000); };
  child.stdout.on("data", append); child.stderr.on("data", append);
  return { child, output: () => output };
}
async function run(args, state) {
  const process = command(args, state);
  const completed = () => {
    const output = process.output();
    if (args[1] !== "migrations") return /commands? executed successfully/.test(output) || /"success": true/.test(output);
    const finalTable = output.slice(output.lastIndexOf("┌"));
    return finalTable.includes("└") && finalTable.includes("✅") && !finalTable.includes("🕒");
  };
  let forced = false, timedOut = false;
  const monitor = setInterval(() => { if (!forced && completed() && process.child.exitCode === null) { forced = true; process.child.kill("SIGTERM"); } }, 100);
  const deadline = setTimeout(() => { timedOut = true; if (process.child.exitCode === null) process.child.kill("SIGTERM"); }, 30_000);
  try {
    const [code, signal] = await once(process.child, "exit");
    assert.equal(timedOut, false, process.output());
    assert.ok(code === 0 || forced && signal === "SIGTERM", process.output());
    if (forced) assert.equal(completed(), true, process.output());
  } finally { clearInterval(monitor); clearTimeout(deadline); }
}
async function stop(process) {
  if (process.child.exitCode === null) process.child.kill("SIGTERM");
  if (process.child.exitCode === null) await once(process.child, "exit");
}
function options(method, token, body) {
  return { method, headers: { authorization: `Bearer ${token}`, ...(body ? { "content-type": "application/json" } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) };
}
async function request(path, init) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, init);
  return { status: response.status, body: await response.json() };
}

// A separate D1 directory and port keep this test independent of the pairing suite.
test("a recipient only receives the approved one-account projection; revocation immediately closes both capabilities", async (context) => {
  const state = await mkdtemp(join(tmpdir(), "quota-island-shares-"));
  let worker;
  context.after(async () => { if (worker) await stop(worker); await rm(state, { recursive: true, force: true }); });
  const base = ["DB", "--local", "--persist-to", state, "--config", "workers/lite/wrangler.jsonc"];
  await run(["d1", "migrations", "apply", ...base], state);
  const now = new Date().toISOString();
  const expired = new Date(Date.now() - 60_000).toISOString();
  const oldClaimed = new Date(Date.now() - 25 * 60 * 60_000).toISOString();
  const insert = `INSERT INTO workspaces VALUES ('share-ws-a','share-writer-a','source-a','synthetic-key','${now}'),('share-ws-b','share-writer-b','source-b','synthetic-key','${now}');
    INSERT INTO devices (device_id,workspace_id,role,name,token_hash,created_at) VALUES
    ('share-writer-a','share-ws-a','writer','Writer A','${await hash(writerToken)}','${now}'),
    ('share-writer-b','share-ws-b','writer','Writer B','${await hash(otherToken)}','${now}'),
    ('full-sync-viewer','share-ws-a','viewer','Full Sync Viewer','${await hash(fullSyncViewerToken)}','${now}');
    INSERT INTO quota_shares (share_id,workspace_id,writer_device_id,connection_id,provider_id,account_id,label,invite_secret_hash,state,expires_at,created_at)
    VALUES ('expired-share','share-ws-a','share-writer-a','connection-a','provider-a','private-account-a','Expired','${await hash(expiredInviteSecret)}','pending','${expired}','${now}');
    INSERT INTO quota_shares (share_id,workspace_id,writer_device_id,connection_id,provider_id,account_id,label,invite_secret_hash,state,claim_id,claim_token_hash,viewer_token_hash,delivery_expires_at,captured_at,windows_json,expires_at,created_at)
    VALUES ('persistent-grant','share-ws-a','share-writer-a','connection-a','provider-a','private-account-a','Persistent','${await hash("seeded-unused-secret")}', 'approved','seeded-claim','${await hash(expiredClaimToken)}','${await hash(persistentViewerToken)}','${expired}','${now}','[]','${expired}','${now}');
    INSERT INTO quota_shares (share_id,workspace_id,writer_device_id,connection_id,provider_id,account_id,label,invite_secret_hash,state,claim_id,claim_token_hash,claimed_at,recipient_name,verification_code,expires_at,created_at)
    VALUES ('old-claim','share-ws-a','share-writer-a','connection-a','provider-a','private-account-a','Old Claim','${await hash("seeded-old-secret")}', 'claimed','old-claim-id','${await hash(oldClaimToken)}','${oldClaimed}','Old Recipient','193827','${expired}','${oldClaimed}');`;
  await run(["d1", "execute", ...base, "--command", insert], state);
  worker = command(["dev", "--local", "--persist-to", state, "--port", String(port), "--var", `DELIVERY_ENCRYPTION_KEY:${Buffer.alloc(32, 7).toString("base64url")}`, "--config", "workers/lite/wrangler.jsonc"], state);
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/v1/capabilities`, { signal: AbortSignal.timeout(1000) })).ok) { ready = true; break; } } catch { /* starting */ }
    if (worker.child.exitCode !== null) assert.fail(worker.output());
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(ready, true, worker.output());

  const expiredClaim = await request("/v1/shares/expired-share/claim", options("POST", expiredInviteSecret, { recipientName: "Too Late" }));
  assert.equal(expiredClaim.status, 401);
  const expiredList = await request("/v1/shares", options("GET", writerToken));
  assert.equal(expiredList.body.find((entry) => entry.shareId === "expired-share").state, "expired");
  const expiredDelivery = await request("/v1/shares/persistent-grant/result", options("GET", expiredClaimToken));
  assert.equal(expiredDelivery.status, 410);
  const persistentGrant = await request("/v1/shares/persistent-grant/projection", options("GET", persistentViewerToken));
  assert.deepEqual(persistentGrant.body, { shareId: "persistent-grant", providerId: "provider-a", label: "Persistent", capturedAt: now, windows: [] });

  const oldClaim = await request("/v1/shares/old-claim/result", options("GET", oldClaimToken));
  assert.equal(oldClaim.status, 410);
  assert.equal((await request("/v1/shares/old-claim/approve", options("POST", writerToken, { claimId: "old-claim-id" }))).status, 404);
  const payload = { connectionId: "connection-a", providerId: "provider-a", accountId: "private-account-a", label: "Personal", inviteSecretHash: await hash(inviteSecret) };
  const created = await request("/v1/shares", options("POST", writerToken, payload));
  assert.equal(created.status, 200); assert.ok(Date.parse(created.body.expiresAt) > Date.now());
  assert.equal((await request("/v1/shares", { method: "GET" })).status, 401);
  const share = created.body.shareId, path = `/v1/shares/${share}`;
  const wrongRole = await request("/v1/shares", options("POST", fullSyncViewerToken, { ...payload, inviteSecretHash: await hash(secondInviteSecret) }));
  assert.equal(wrongRole.status, 403);
  const foreignList = await request("/v1/shares", options("GET", otherToken));
  assert.deepEqual(foreignList.body, []);
  const foreignRevoke = await request(path, options("DELETE", otherToken));
  assert.equal(foreignRevoke.status, 404);
  const foreignApprove = await request(`${path}/approve`, options("POST", otherToken, { claimId: "unclaimed" }));
  assert.equal(foreignApprove.status, 404);
  const incorrectSecret = await request(`${path}/claim`, options("POST", secondInviteSecret, { recipientName: "Impostor" }));
  assert.equal(incorrectSecret.status, 401);
  const claims = await Promise.all(Array.from({ length: 2 }, () => request(`${path}/claim`, options("POST", inviteSecret, { recipientName: "Recipient" }))));
  assert.deepEqual(claims.map((result) => result.status).sort(), [200, 409]);
  const claim = claims.find((result) => result.status === 200).body;
  assert.match(claim.verificationCode, /^\d{6}$/);
  assert.equal((await request(`${path}/approve`, options("POST", otherToken, { claimId: claim.claimId }))).status, 404);
  const listed = await request("/v1/shares", options("GET", writerToken));
  const record = listed.body.find((entry) => entry.shareId === share);
  assert.equal(record.accountId, "private-account-a");
  assert.equal(record.recipientName, "Recipient");
  assert.equal(record.claimId, claim.claimId);
  assert.equal(record.verificationCode, claim.verificationCode);
  assert.equal(record.state, "claimed");
  const pending = await request(`${path}/result`, options("GET", claim.claimToken));
  assert.deepEqual(pending.body, { state: "claimed" });
  const unapprovedRead = await request(`${path}/projection`, options("GET", claim.claimToken));
  assert.equal(unapprovedRead.status, 401);
  const wrongClaim = await request(`${path}/approve`, options("POST", writerToken, { claimId: "wrong-claim" }));
  assert.equal(wrongClaim.status, 404);
  const approval = await request(`${path}/approve`, options("POST", writerToken, { claimId: claim.claimId }));
  assert.deepEqual(approval, { status: 200, body: { state: "approved" } });
  const issued = await request(`${path}/result`, options("GET", claim.claimToken));
  assert.equal(issued.status, 200); assert.equal(issued.body.state, "approved"); assert.ok(issued.body.viewerToken);
  const viewerToken = issued.body.viewerToken;
  const repeat = await request(`${path}/result`, options("GET", claim.claimToken));
  assert.equal(repeat.body.viewerToken, viewerToken);
  const blank = await request(`${path}/projection`, options("GET", viewerToken));
  assert.equal(blank.status, 404);

  const timestamp = new Date().toISOString();
  const windows = [{ quotaKey: "daily", unit: "money", currency: "USD", availability: "available", remainingBps: 7500, amount: "7.5", limit: "10", quality: "reported", fetchOutcome: "ok", observedAt: timestamp, staleAt: null, resetsAt: null }];
  const projection = { capturedAt: timestamp, windows };
  for (const invalid of [{ ...projection, accountId: "private-account-a" }, { ...projection, windows: [{ ...windows[0], accountId: "private-account-a" }] }, { ...projection, windows: Array(81).fill(windows[0]) }, { ...projection, windows: [{ ...windows[0], remainingBps: 10001 }] }]) {
    const rejected = await request(`${path}/projection`, options("PUT", writerToken, invalid));
    assert.equal(rejected.status, 400);
  }
  const foreignPublish = await request(`${path}/projection`, options("PUT", otherToken, projection));
  assert.equal(foreignPublish.status, 409);
  const published = await request(`${path}/projection`, options("PUT", writerToken, projection));
  assert.deepEqual(published, { status: 200, body: { accepted: true } });
  const read = await request(`${path}/projection`, options("GET", viewerToken));
  assert.deepEqual(read.body, { shareId: share, providerId: "provider-a", label: "Personal", ...projection });
  assert.equal(JSON.stringify(read.body).includes("private-account-a"), false);
  const cannotReadWithClaimToken = await request(`${path}/projection`, options("GET", claim.claimToken));
  assert.equal(cannotReadWithClaimToken.status, 401);
  const cannotReadWithSyncViewer = await request(`${path}/projection`, options("GET", fullSyncViewerToken));
  assert.equal(cannotReadWithSyncViewer.status, 401);

  const second = await request("/v1/shares", options("POST", writerToken, { ...payload, accountId: "private-account-b", inviteSecretHash: await hash(secondInviteSecret) }));
  assert.equal(second.status, 200);
  const secondPath = `/v1/shares/${second.body.shareId}`;
  assert.equal((await request(`${secondPath}/projection`, options("GET", viewerToken))).status, 401);
  assert.equal((await request(`${secondPath}/result`, options("GET", claim.claimToken))).status, 401);
  assert.equal((await request(`${secondPath}/claim`, options("POST", inviteSecret, { recipientName: "Recipient" }))).status, 401);

  assert.deepEqual(await request(path, options("DELETE", writerToken)), { status: 200, body: { state: "revoked" } });
  assert.equal((await request(`${path}/projection`, options("GET", viewerToken))).status, 401);
  assert.equal((await request(`${path}/result`, options("GET", claim.claimToken))).status, 401);
  assert.equal((await request(`${path}/claim`, options("POST", inviteSecret, { recipientName: "Other" }))).status, 401);
  assert.deepEqual(await request(path, options("DELETE", writerToken)), { status: 200, body: { state: "revoked" } });
  assert.equal((await request(`${secondPath}/claim`, options("POST", secondInviteSecret, { recipientName: "New Recipient" }))).status, 200);
});
