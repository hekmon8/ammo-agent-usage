import { verifyExternalMCP } from "./external-mcp.mjs";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

const root = new URL("../../..", import.meta.url).pathname;
const wrangler = process.env.WRANGLER_BIN ?? join(root, "workers/lite/node_modules/.bin/wrangler");
const port = 18791;
const state = await mkdtemp(join(tmpdir(), "quota-island-d1-"));
const secret = "synthetic-bootstrap-secret-only";
const encryptionKey = Buffer.alloc(32, 7).toString("base64url");
const signingKey = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const sourceKey = Buffer.from(await crypto.subtle.exportKey("raw", signingKey.publicKey)).toString("base64url");
const recipientKey = Buffer.alloc(32, 2).toString("base64url");
const pairingSecret = "p".repeat(43);

function command(args) {
  const child = spawn(wrangler, args, { cwd: root, env: { ...process.env, WRANGLER_LOG_PATH: join(state, "wrangler.log"), WRANGLER_REGISTRY_PATH: join(state, "registry") }, stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  const append = (data) => { output = (output + data.toString()).slice(-12_000); };
  child.stdout.on("data", append); child.stderr.on("data", append);
  return { child, output: () => output };
}
async function run(args) {
  const process = command(args);
  const completed = () => {
    const output = process.output();
    if (args[1] !== "migrations") return /commands? executed successfully/.test(output) || /"success": true/.test(output);
    const finalTable = output.slice(output.lastIndexOf("┌"));
    return finalTable.includes("└") && finalTable.includes("✅") && !finalTable.includes("🕒");
  };
  // Wrangler 4.98 can retain its local D1 process after reporting success.
  // Close that process only after its final success output; fail if it never arrives.
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
async function startWorker(state, port, vars) {
  const worker = command(["dev", "--local", "--persist-to", state, "--port", String(port), "--var", "BOOTSTRAP_ENABLED:true", "--var", `DELIVERY_ENCRYPTION_KEY:${encryptionKey}`, ...vars, "--config", "workers/lite/wrangler.jsonc"]);
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/v1/capabilities`, { signal: AbortSignal.timeout(1000) })).ok) { ready = true; break; } } catch { /* starting */ }
    if (worker.child.exitCode !== null) assert.fail(`local Worker exited before readiness:\n${worker.output()}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(ready, true, `local Worker did not become ready:\n${worker.output()}`);
  return worker;
}
async function request(path, options = {}) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, options);
  return { response, body: await response.json() };
}
function encoded(bytes) { return Buffer.from(bytes).toString("base64url"); }
async function signedEnvelope(writer, sequence, key = signingKey) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = crypto.getRandomValues(new Uint8Array(24));
  const tag = crypto.getRandomValues(new Uint8Array(16));
  const keyId = "key1";
  const header = `QI|1|${writer.workspaceId}|${writer.deviceId}|${writer.sourceEpoch}|${sequence}|${keyId}`;
  const signed = Buffer.concat([Buffer.from(header), Buffer.from("\n"), Buffer.from(nonce), Buffer.from(ciphertext), Buffer.from(tag)]);
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, key.privateKey, signed);
  const contentHash = Buffer.from(await crypto.subtle.digest("SHA-256", signed)).toString("hex");
  return { schemaVersion: "1.0.0", workspaceId: writer.workspaceId, sourceDeviceId: writer.deviceId, sourceEpoch: writer.sourceEpoch, sequence, keyId, nonce: encoded(nonce), ciphertext: encoded(ciphertext), tag: encoded(tag), signature: encoded(signature), contentHash };
}
async function signedRotation(writer, viewerDeviceId) {
  const nextKey = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const newSourcePublicKey = Buffer.from(await crypto.subtle.exportKey("raw", nextKey.publicKey)).toString("base64url");
  const newSourceEpoch = "rotated_epoch_1"; const keyId = "rotated_key_1";
  const context = `${writer.workspaceId}|${writer.deviceId}|${newSourceEpoch}|${keyId}|${viewerDeviceId}`;
  const encapsulatedKey = encoded(crypto.getRandomValues(new Uint8Array(32)));
  const ciphertext = encoded(crypto.getRandomValues(new Uint8Array(48)));
  const wrapBytes = Buffer.concat([Buffer.from(`QI-WRAP|1|${context}\n`), Buffer.from(encapsulatedKey, "base64url"), Buffer.from(ciphertext, "base64url")]);
  const wrapSignature = encoded(await crypto.subtle.sign({ name: "Ed25519" }, signingKey.privateKey, wrapBytes));
  const wrappedSnapshotKey = encoded(Buffer.from(JSON.stringify({ version: 1, suite: "X25519-HKDF-SHA256-AES256GCM", context, encapsulatedKey, ciphertext, signature: wrapSignature })));
  const wraps = [{ deviceId: viewerDeviceId, wrappedSnapshotKey }];
  const header = `QI-ROTATE|1|${writer.workspaceId}|${writer.deviceId}|${writer.sourceEpoch}|${newSourceEpoch}|${newSourcePublicKey}|${keyId}`;
  const signature = encoded(await crypto.subtle.sign({ name: "Ed25519" }, signingKey.privateKey, Buffer.from(`${header}\n${viewerDeviceId}|${wrappedSnapshotKey}\n`)));
  const trustHeader = `QI-ROTATION-TRUST|1|${writer.workspaceId}|${writer.deviceId}|${writer.sourceEpoch}|${newSourceEpoch}|${newSourcePublicKey}|${keyId}`;
  const trustSignature = encoded(await crypto.subtle.sign({ name: "Ed25519" }, signingKey.privateKey, Buffer.from(trustHeader)));
  return { request: { userConfirmation: "rotate_source_key", oldSourceEpoch: writer.sourceEpoch, newSourceEpoch, newSourcePublicKey, keyId, wraps, signature, trustSignature }, nextKey };
}

test("P2-01 worker enforces pairing, acknowledgement, and immediate revocation at the HTTP boundary", async (context) => {
  let worker;
  context.after(async () => { if (worker) await stop(worker); await rm(state, { recursive: true, force: true }); });
  await run(["d1", "migrations", "apply", "DB", "--local", "--persist-to", state, "--config", "workers/lite/wrangler.jsonc"]);
  const otherHash = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("synthetic-other-writer-token-0000000000"))).toString("hex");
  await run(["d1", "execute", "DB", "--local", "--persist-to", state, "--config", "workers/lite/wrangler.jsonc", "--command", `INSERT INTO workspaces VALUES ('other-ws','other-writer','other-epoch','synthetic-key','2026-01-01T00:00:00.000Z'); INSERT INTO devices (device_id,workspace_id,role,name,token_hash,created_at) VALUES ('other-writer','other-ws','writer','Other','${otherHash}','2026-01-01T00:00:00.000Z');`]);
  const secondMCPHash = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("synthetic-other-mcp-token-000000000000"))).toString("hex");
  const expiredMCPHash = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("synthetic-expired-mcp-token-0000000000"))).toString("hex");
  await run(["d1", "execute", "DB", "--local", "--persist-to", state, "--config", "workers/lite/wrangler.jsonc", "--command", `INSERT INTO mcp_access (workspace_id,token_hash,source_epoch,expires_at) VALUES ('other-ws','${secondMCPHash}','other-epoch','2099-01-01T00:00:00.000Z'); INSERT INTO workspaces VALUES ('expired-ws','expired-writer','expired-epoch','synthetic-key','2026-01-01T00:00:00.000Z'); INSERT INTO devices (device_id,workspace_id,role,name,token_hash,created_at) VALUES ('expired-writer','expired-ws','writer','Expired','unused-synthetic-writer-hash','2026-01-01T00:00:00.000Z'); INSERT INTO mcp_access (workspace_id,token_hash,source_epoch,expires_at) VALUES ('expired-ws','${expiredMCPHash}','expired-epoch','2000-01-01T00:00:00.000Z');`]);
  worker = command(["dev", "--local", "--persist-to", state, "--port", String(port), "--var", "BOOTSTRAP_ENABLED:true", "--var", `BOOTSTRAP_SECRET:${secret}`, "--var", `DELIVERY_ENCRYPTION_KEY:${encryptionKey}`, "--config", "workers/lite/wrangler.jsonc"]);
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/v1/capabilities`, { signal: AbortSignal.timeout(1000) })).ok) { ready = true; break; } } catch { /* starting */ }
    if (worker.child.exitCode !== null) assert.fail(`local Worker exited before readiness:\n${worker.output()}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(ready, true, `local Worker did not become ready:\n${worker.output()}`);

  const capabilities = await request("/v1/capabilities");
  assert.equal(capabilities.response.status, 200); assert.deepEqual(capabilities.body.schemaVersions, ["1.0.0"]); assert.equal(capabilities.body.maxEnvelopeBytes, 262144);
  const rejectedBoot = await request("/v1/bootstrap", { method: "POST", headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Test Mac", sourcePublicKey: sourceKey }) });
  assert.equal(rejectedBoot.response.status, 401); assert.equal(rejectedBoot.body.code, "invalid_credential");
  const bootstrapPayload = { deviceName: "Test Mac", sourcePublicKey: sourceKey, requestId: "synthetic_bootstrap_1" };
  const boot = await request("/v1/bootstrap", { method: "POST", headers: { "x-bootstrap-token": secret, "content-type": "application/json" }, body: JSON.stringify(bootstrapPayload) });
  assert.equal(boot.response.status, 200); const writer = boot.body;
  await verifyExternalMCP(`http://127.0.0.1:${port}`, writer, { deviceToken: "synthetic-other-writer-token-0000000000" });
  const bootstrapRetries = await Promise.all([request("/v1/bootstrap", { method: "POST", headers: { "x-bootstrap-token": secret, "content-type": "application/json" }, body: JSON.stringify(bootstrapPayload) }), request("/v1/bootstrap", { method: "POST", headers: { "x-bootstrap-token": secret, "content-type": "application/json" }, body: JSON.stringify(bootstrapPayload) })]);
  for (const retry of bootstrapRetries) { assert.equal(retry.response.status, 200); assert.deepEqual(retry.body, writer); }
  const bootstrapMismatch = await request("/v1/bootstrap", { method: "POST", headers: { "x-bootstrap-token": secret, "content-type": "application/json" }, body: JSON.stringify({ ...bootstrapPayload, sourcePublicKey: Buffer.alloc(32, 9).toString("base64url") }) });
  assert.equal(bootstrapMismatch.response.status, 409);
  const secretHash = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(pairingSecret))).toString("hex");
  const created = await request("/v1/pairings", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ pairingSecretHash: secretHash }) });
  assert.equal(created.response.status, 200); const pairingId = created.body.pairingId;
  const claimOptions = { method: "POST", headers: { authorization: `Bearer ${pairingSecret}`, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Test Phone", recipientPublicKey: recipientKey }) };
  const claims = await Promise.all([request(`/v1/pairings/${pairingId}/claim`, claimOptions), request(`/v1/pairings/${pairingId}/claim`, claimOptions)]);
  assert.deepEqual(claims.map(({ response }) => response.status).sort(), [200, 409]);
  const claim = claims.find(({ response }) => response.status === 200).body;
  const inspected = await request(`/v1/pairings/${pairingId}`, { headers: { authorization: `Bearer ${writer.deviceToken}` } });
  assert.equal(inspected.body.state, "claimed"); assert.equal(inspected.body.claimId, claim.claimId);
  const approved = await request(`/v1/pairings/${pairingId}/approve`, { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ claimId: claim.claimId, wrappedSnapshotKey: "opaque-hpke-ciphertext", keyId: "key1", sourcePublicKey: sourceKey }) });
  assert.equal(approved.response.status, 200);
  const result = await request(`/v1/pairings/${pairingId}/result`, { headers: { authorization: `Bearer ${claim.claimToken}` } });
  assert.equal(result.response.status, 200); assert.equal(result.body.state, "approved"); assert.equal(result.body.workspaceId, writer.workspaceId);
  const devices = await request("/v1/devices", { headers: { authorization: `Bearer ${writer.deviceToken}` } });
  assert.equal(devices.body.length, 2); const viewer = devices.body.find((device) => device.role === "viewer"); const listedWriter = devices.body.find((device) => device.role === "writer");
  assert.equal(viewer.recipientPublicKey, recipientKey); assert.equal(listedWriter.recipientPublicKey, null);
  const envelope = await signedEnvelope(writer, 1);
  const snapshotPut = { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(envelope) };
  const firstSnapshot = await request("/v1/snapshot", snapshotPut);
  assert.equal(firstSnapshot.response.status, 200); assert.equal(firstSnapshot.body.sourceSequence, 1);
  const retries = await Promise.all([request("/v1/snapshot", snapshotPut), request("/v1/snapshot", snapshotPut)]);
  assert.deepEqual(retries.map(({ response }) => response.status), [200, 200]); assert.equal(retries[0].body.serverRevision, firstSnapshot.body.serverRevision); assert.equal(retries[1].body.serverRevision, firstSnapshot.body.serverRevision);
  const conflictingEnvelope = await signedEnvelope(writer, 1);
  const conflictingSnapshot = await request("/v1/snapshot", { ...snapshotPut, body: JSON.stringify(conflictingEnvelope) });
  assert.equal(conflictingSnapshot.response.status, 409);
  // The final base64url character of a 64-byte signature has unused pad bits.
  // Change an encoded byte that Ed25519 verification must observe.
  const tampered = { ...envelope, signature: `${envelope.signature[0] === "A" ? "B" : "A"}${envelope.signature.slice(1)}` };
  const rejectedSnapshot = await request("/v1/snapshot", { ...snapshotPut, body: JSON.stringify(tampered) });
  assert.equal(rejectedSnapshot.response.status, 403);
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const finalIndex = alphabet.indexOf(envelope.signature.at(-1));
  const noncanonical = { ...envelope, signature: `${envelope.signature.slice(0, -1)}${alphabet[finalIndex ^ 1]}` };
  const rejectedNoncanonical = await request("/v1/snapshot", { ...snapshotPut, body: JSON.stringify(noncanonical) });
  assert.equal(rejectedNoncanonical.response.status, 400);
  // One byte past the worker's snapshotBodyLimit (256 KiB envelope budget).
  const oversized = await request("/v1/snapshot", { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ padding: "x".repeat(256 * 1024 + 1) }) });
  assert.equal(oversized.response.status, 413);
  const snapshot = await request("/v1/snapshot", { headers: { authorization: `Bearer ${result.body.deviceToken}` } });
  assert.equal(snapshot.response.status, 200); assert.deepEqual(snapshot.body.envelope, envelope); assert.ok(snapshot.response.headers.get("etag"));
  const cached = await fetch(`http://127.0.0.1:${port}/v1/snapshot`, { headers: { authorization: `Bearer ${result.body.deviceToken}`, "if-none-match": snapshot.response.headers.get("etag") } });
  assert.equal(cached.status, 304);
  for (const response of [snapshot.response, cached]) assert.ok(Math.abs(Date.parse(response.headers.get("date")) - Date.now()) < 10000);
  const activityId = "synthetic_activity_1";
  const activityPayload = { windowId: "window1", activityToken: "synthetic-activity-token-a", environment: "sandbox", endsAt: new Date(Date.now() + 60 * 60_000).toISOString(), projectionConsent: true };
  const activity = await request(`/v1/activities/${activityId}`, { method: "PUT", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(activityPayload) });
  assert.equal(activity.response.status, 200);
  const writerRegisterViolation = await request("/v1/activities/writer_owned_activity", { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(activityPayload) });
  assert.equal(writerRegisterViolation.response.status, 403);
  const rotatedToken = await request(`/v1/activities/${activityId}`, { method: "PUT", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...activityPayload, activityToken: "synthetic-activity-token-b" }) });
  assert.equal(rotatedToken.response.status, 200);
  // Re-registration by the owning device rolls the deadline forward; each value
  // stays bounded to +activityLifetimeMs by the endpoint's own validation.
  const extendedEnd = new Date(Date.now() + 3.5 * 60 * 60_000).toISOString();
  const extended = await request(`/v1/activities/${activityId}`, { method: "PUT", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...activityPayload, activityToken: "synthetic-activity-token-b", endsAt: extendedEnd }) });
  assert.equal(extended.response.status, 200);
  const beyondLifetime = await request(`/v1/activities/${activityId}`, { method: "PUT", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...activityPayload, activityToken: "synthetic-activity-token-b", endsAt: new Date(Date.now() + 5 * 60 * 60_000).toISOString() }) });
  assert.equal(beyondLifetime.response.status, 400);
  const expiredSession = await request("/v1/activities/expired_activity", { method: "PUT", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...activityPayload, endsAt: new Date(Date.now() - 1_000).toISOString() }) });
  assert.equal(expiredSession.response.status, 400);
  const writerOwnViolation = await request(`/v1/activities/${activityId}`, { method: "DELETE", headers: { authorization: `Bearer ${writer.deviceToken}` } });
  assert.equal(writerOwnViolation.response.status, 403);
  const projection = { sequence: 1, windowId: "window1", label: "Quota", remainingBps: 6800, displayState: "fresh", observedAt: new Date().toISOString(), staleAt: new Date(Date.now() + 600_000).toISOString(), resetsAt: null };
  const unavailablePush = await request("/v1/live-projections", { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(projection) });
  assert.equal(unavailablePush.response.status, 200); assert.equal(unavailablePush.body.ok, true);
  const retryPush = await request("/v1/live-projections", { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(projection) });
  assert.equal(retryPush.response.status, 200);
  const changedRetry = await request("/v1/live-projections", { method: "PUT", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...projection, remainingBps: 6500 }) });
  assert.equal(changedRetry.response.status, 409);
  const ended = await request(`/v1/activities/${activityId}`, { method: "DELETE", headers: { authorization: `Bearer ${result.body.deviceToken}` } });
  assert.equal(ended.response.status, 200);
  const acknowledged = await request(`/v1/pairings/${pairingId}/ack`, { method: "POST", headers: { authorization: `Bearer ${claim.claimToken}`, "content-type": "application/json" }, body: JSON.stringify({ claimId: claim.claimId }) });
  assert.equal(acknowledged.response.status, 200);
  const consumed = await request(`/v1/pairings/${pairingId}/result`, { headers: { authorization: `Bearer ${claim.claimToken}` } });
  assert.equal(consumed.body.state, "consumed"); assert.equal(consumed.body.deviceToken, null);
  const pendingSecret = "q".repeat(43);
  const pendingHash = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(pendingSecret))).toString("hex");
  const pending = await request("/v1/pairings", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ pairingSecretHash: pendingHash }) });
  assert.equal(pending.response.status, 200);
  const rotation = await signedRotation(writer, viewer.deviceId);
  const rotationHeader = `QI-ROTATE|1|${writer.workspaceId}|${writer.deviceId}|${rotation.request.oldSourceEpoch}|${rotation.request.newSourceEpoch}|${rotation.request.newSourcePublicKey}|${rotation.request.keyId}`;
  const incomplete = { ...rotation.request, wraps: [], signature: encoded(await crypto.subtle.sign({ name: "Ed25519" }, signingKey.privateKey, Buffer.from(`${rotationHeader}\n`))) };
  const incompleteRotation = await request("/v1/source-key-rotations", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(incomplete) });
  assert.equal(incompleteRotation.response.status, 409);
  const invalidTrust = await request("/v1/source-key-rotations", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ ...rotation.request, trustSignature: `${rotation.request.trustSignature[0] === "A" ? "B" : "A"}${rotation.request.trustSignature.slice(1)}` }) });
  assert.equal(invalidTrust.response.status, 403);
  const rotated = await request("/v1/source-key-rotations", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(rotation.request) });
  assert.equal(rotated.response.status, 200); assert.equal(rotated.body.sourceEpoch, rotation.request.newSourceEpoch);
  const rotationRetry = await request("/v1/source-key-rotations", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(rotation.request) });
  assert.equal(rotationRetry.response.status, 200); assert.deepEqual(rotationRetry.body, rotated.body);
  const changedRotation = { ...rotation.request, wraps: [{ ...rotation.request.wraps[0], wrappedSnapshotKey: `${rotation.request.wraps[0].wrappedSnapshotKey[0] === "A" ? "B" : "A"}${rotation.request.wraps[0].wrappedSnapshotKey.slice(1)}` }] };
  const rejectedRotationRetry = await request("/v1/source-key-rotations", { method: "POST", headers: { authorization: `Bearer ${writer.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(changedRotation) });
  assert.equal(rejectedRotationRetry.response.status, 409);
  const staleSnapshot = await request("/v1/snapshot", { headers: { authorization: `Bearer ${result.body.deviceToken}` } });
  assert.equal(staleSnapshot.response.status, 404);
  const ownWrap = await request("/v1/device-key-wrap", { headers: { authorization: `Bearer ${result.body.deviceToken}` } });
  assert.equal(ownWrap.response.status, 200); assert.equal(ownWrap.body.wrappedSnapshotKey, rotation.request.wraps[0].wrappedSnapshotKey);
  assert.equal(ownWrap.body.oldSourceEpoch, writer.sourceEpoch); assert.equal(ownWrap.body.newSourcePublicKey, rotation.request.newSourcePublicKey); assert.equal(ownWrap.body.trustSignature, rotation.request.trustSignature); assert.equal(ownWrap.body.sourceDeviceId, writer.deviceId);
  const oldPairingClaim = await request(`/v1/pairings/${pending.body.pairingId}/claim`, { method: "POST", headers: { authorization: `Bearer ${pendingSecret}`, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Old Pairing", recipientPublicKey: recipientKey }) });
  assert.equal(oldPairingClaim.response.status, 401);
  const revoked = await request(`/v1/devices/${viewer.deviceId}`, { method: "DELETE", headers: { authorization: `Bearer ${writer.deviceToken}` } });
  assert.equal(revoked.response.status, 200);
  const revokedRead = await request("/v1/snapshot", { headers: { authorization: `Bearer ${result.body.deviceToken}`, "if-none-match": snapshot.response.headers.get("etag") } });
  assert.equal(revokedRead.response.status, 401);
  const blocked = await request("/v1/pairings", { method: "POST", headers: { authorization: `Bearer ${result.body.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify({ pairingSecretHash: secretHash }) });
  assert.equal(blocked.response.status, 401);
});

test("P2-02 worker provisions one workspace per bootstrap token and keeps the legacy secret bounded", async (context) => {
  let worker;
  const tenantState = await mkdtemp(join(tmpdir(), "quota-island-d1-tenants-"));
  const tenantPort = 18793;
  context.after(async () => { if (worker) await stop(worker); await rm(tenantState, { recursive: true, force: true }); });
  await run(["d1", "migrations", "apply", "DB", "--local", "--persist-to", tenantState, "--config", "workers/lite/wrangler.jsonc"]);
  // Simulate a deployment that completed bootstrap before 0009.
  await run(["d1", "execute", "DB", "--local", "--persist-to", tenantState, "--config", "workers/lite/wrangler.jsonc", "--command", `INSERT INTO bootstrap_state (singleton, completed_at) VALUES (1, '2026-01-01T00:00:00.000Z');`]);
  worker = command(["dev", "--local", "--persist-to", tenantState, "--port", String(tenantPort), "--var", "BOOTSTRAP_ENABLED:true", "--var", `BOOTSTRAP_SECRET:${secret}`, "--var", `BOOTSTRAP_SECRETS:${JSON.stringify(["tenant-token-a", "tenant-token-b"])}`, "--var", `DELIVERY_ENCRYPTION_KEY:${encryptionKey}`, "--config", "workers/lite/wrangler.jsonc"]);
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { if ((await fetch(`http://127.0.0.1:${tenantPort}/v1/capabilities`)).ok) { ready = true; break; } } catch { /* starting */ }
    if (worker.child.exitCode !== null) assert.fail(`local Worker exited before readiness:\n${worker.output()}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(ready, true, `local Worker did not become ready:\n${worker.output()}`);
  const tenantRequest = async (path, options = {}) => { const response = await fetch(`http://127.0.0.1:${tenantPort}${path}`, options); return { response, body: await response.json() }; };
  const exportKeyPair = async () => crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const exportPublic = async () => Buffer.from(await crypto.subtle.exportKey("raw", (await exportKeyPair()).publicKey)).toString("base64url");
  const tenantBoot = async (token, requestId, sourceKey) => tenantRequest("/v1/bootstrap", { method: "POST", headers: { "x-bootstrap-token": token, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Tenant Mac", sourcePublicKey: sourceKey, requestId }) });

  // The legacy secret stays bound to the pre-0009 workspace even with a fresh idempotency key.
  const legacyBlocked = await tenantBoot(secret, "tenant_legacy_blocked", await exportPublic());
  assert.equal(legacyBlocked.response.status, 409); assert.equal(legacyBlocked.body.code, "bootstrap_already_completed");
  const unknownToken = await tenantBoot("tenant-token-c", "tenant_unknown", await exportPublic());
  assert.equal(unknownToken.response.status, 401); assert.equal(unknownToken.body.code, "invalid_credential");

  const keyA = await exportKeyPair(); const keyB = await exportKeyPair(); const keyRetry = await exportPublic();
  const writerA = (await tenantBoot("tenant-token-a", "tenant_bootstrap_a", Buffer.from(await crypto.subtle.exportKey("raw", keyA.publicKey)).toString("base64url"))).body;
  const writerB = (await tenantBoot("tenant-token-b", "tenant_bootstrap_b", Buffer.from(await crypto.subtle.exportKey("raw", keyB.publicKey)).toString("base64url"))).body;
  assert.ok(writerA.workspaceId && writerB.workspaceId); assert.notEqual(writerB.workspaceId, writerA.workspaceId);
  assert.notEqual(writerB.deviceToken, writerA.deviceToken);

  const reusedToken = await tenantBoot("tenant-token-a", "tenant_bootstrap_a_new_request", keyRetry);
  assert.equal(reusedToken.response.status, 409); assert.equal(reusedToken.body.code, "bootstrap_already_completed");
  const replayed = await tenantBoot("tenant-token-a", "tenant_bootstrap_a", Buffer.from(await crypto.subtle.exportKey("raw", keyA.publicKey)).toString("base64url"));
  assert.equal(replayed.response.status, 200); assert.deepEqual(replayed.body, writerA);

  // Tenant isolation: writer B cannot store a correctly signed envelope that belongs to workspace A.
  const foreignEnvelope = await signedEnvelope(writerA, 1, keyA);
  const foreignPut = await tenantRequest("/v1/snapshot", { method: "PUT", headers: { authorization: `Bearer ${writerB.deviceToken}`, "content-type": "application/json" }, body: JSON.stringify(foreignEnvelope) });
  assert.equal(foreignPut.response.status, 403); assert.equal(foreignPut.body.code, "invalid_source_proof");
});

test("P2-03 a rotated legacy secret cannot reopen bootstrap on a fresh deployment", async (context) => {
  let worker;
  const rotationState = await mkdtemp(join(tmpdir(), "quota-island-d1-rotation-"));
  const rotationPort = 18795;
  context.after(async () => { if (worker) await stop(worker); await rm(rotationState, { recursive: true, force: true }); });
  await run(["d1", "migrations", "apply", "DB", "--local", "--persist-to", rotationState, "--config", "workers/lite/wrangler.jsonc"]);
  const boot = async (token, requestId) => {
    const response = await fetch(`http://127.0.0.1:${rotationPort}/v1/bootstrap`, { method: "POST", headers: { "x-bootstrap-token": token, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Rotation Mac", sourcePublicKey: sourceKey, requestId }) });
    return { status: response.status, body: await response.json() };
  };
  worker = await startWorker(rotationState, rotationPort, [`BOOTSTRAP_SECRET:${secret}`]);
  const first = await boot(secret, "rotation_bootstrap_1");
  assert.equal(first.status, 200);
  await stop(worker);
  worker = await startWorker(rotationState, rotationPort, ["BOOTSTRAP_SECRET:rotated-bootstrap-secret"]);
  const rotated = await boot("rotated-bootstrap-secret", "rotation_bootstrap_2");
  assert.equal(rotated.status, 409); assert.equal(rotated.body.code, "bootstrap_already_completed");
});

test("P2-04 the tenant token cap excludes the legacy credential", async (context) => {
  let worker;
  const capState = await mkdtemp(join(tmpdir(), "quota-island-d1-cap-"));
  const capPort = 18797;
  context.after(async () => { if (worker) await stop(worker); await rm(capState, { recursive: true, force: true }); });
  await run(["d1", "migrations", "apply", "DB", "--local", "--persist-to", capState, "--config", "workers/lite/wrangler.jsonc"]);
  const listed = Array.from({ length: 128 }, (_, index) => `cap-token-${index}`);
  worker = await startWorker(capState, capPort, [`BOOTSTRAP_SECRET:${secret}`, `BOOTSTRAP_SECRETS:${JSON.stringify(listed)}`]);
  const capBoot = async (token, requestId) => {
    const response = await fetch(`http://127.0.0.1:${capPort}/v1/bootstrap`, { method: "POST", headers: { "x-bootstrap-token": token, "content-type": "application/json" }, body: JSON.stringify({ deviceName: "Cap Mac", sourcePublicKey: sourceKey, requestId }) });
    return { status: response.status, body: await response.json() };
  };
  // The 128th listed token must provision even though the legacy secret is configured.
  const lastListed = await capBoot("cap-token-127", "cap_bootstrap_127");
  assert.equal(lastListed.status, 200);
  const beyondListed = await capBoot("cap-token-128", "cap_bootstrap_128");
  assert.equal(beyondListed.status, 401);
  const legacy = await capBoot(secret, "cap_bootstrap_legacy");
  assert.equal(legacy.status, 200);
});
