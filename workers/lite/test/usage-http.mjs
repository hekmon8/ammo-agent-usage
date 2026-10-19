import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, readdir, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import test from "node:test";

const root = new URL("../../..", import.meta.url).pathname;
const wrangler = process.env.WRANGLER_BIN ?? join(root, "workers/lite/node_modules/.bin/wrangler");
const port = 18823;
const inProcess = process.env.AMMO_USAGE_SQLITE === "1";
let fetchWorker = globalThis.fetch;
const writerToken = "synthetic-usage-writer-token-00000001";
const viewerToken = "synthetic-usage-viewer-token-00000001";
const otherToken = "synthetic-usage-viewer-token-00000002";
const rogueToken = "synthetic-usage-rogue-writer-00000001";
const signingKey = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const encoded = (bytes) => Buffer.from(bytes).toString("base64url");
const hash = async (text) => Buffer.from(await crypto.subtle.digest("SHA-256", typeof text === "string" ? new TextEncoder().encode(text) : text)).toString("hex");
const sourceKey = encoded(await crypto.subtle.exportKey("raw", signingKey.publicKey));
const cipherKey = await crypto.subtle.importKey("raw", Buffer.alloc(32, 19), "AES-GCM", false, ["encrypt", "decrypt"]);
const source = { workspaceId: "usage-ws", sourceDeviceId: "usage-mac", sourceEpoch: "usage-epoch", keyId: "usage-key" };
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
  const response = await fetchWorker(`http://127.0.0.1:${port}${path}`, { ...init, headers: { ...init?.headers, "cf-connecting-ip": "198.51.100.23" } });
  return { status: response.status, body: await response.json() };
}


async function envelope(sequence, { domain = "QI-USAGE", fields = {}, bytes, tokens = sequence * 100 } = {}) {
  const e = { schemaVersion: "1.0.0", ...source, sequence, ...fields };
  const header = `${domain}|1|${e.workspaceId}|${e.sourceDeviceId}|${e.sourceEpoch}|${e.sequence}|${e.keyId}`;
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  // Synthetic aggregate only; no local provider files or credentials are read.
  const plaintext = bytes ?? Buffer.from(JSON.stringify({ buckets: [{ day: "2026-10-02", agent: "codex", tokens: { nonCachedInput: tokens, cacheRead: 0, cacheWrite: 0, output: 0 } }] }));
  const sealed = Buffer.from(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: Buffer.from(header) }, cipherKey, plaintext));
  const ciphertext = sealed.subarray(0, -16), tag = sealed.subarray(-16);
  const signed = Buffer.concat([Buffer.from(header + "\n"), nonce, ciphertext, tag]);
  return { ...e, nonce: encoded(nonce), ciphertext: encoded(ciphertext), tag: encoded(tag), signature: encoded(await crypto.subtle.sign("Ed25519", signingKey.privateKey, signed)), contentHash: await hash(signed) };
}
async function open(e) {
  const header = `QI-USAGE|1|${e.workspaceId}|${e.sourceDeviceId}|${e.sourceEpoch}|${e.sequence}|${e.keyId}`;
  const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: Buffer.from(e.nonce, "base64url"), additionalData: Buffer.from(header) }, cipherKey, Buffer.concat([Buffer.from(e.ciphertext, "base64url"), Buffer.from(e.tag, "base64url")]));
  return JSON.parse(Buffer.from(plaintext).toString());
}

// Optional real SQLite + actual Worker Request/Response boundary for containers
// whose kernel cannot enumerate network interfaces for Wrangler's HTTP listener.
// This is not a hand-written SQL/auth mock; all production SQL executes unchanged.
async function sqliteWorker(state) {
  const { DatabaseSync } = await import("node:sqlite");
  const { default: ts } = await import("typescript");
  const db = new DatabaseSync(":memory:");
  const migrations = new URL("../migrations/", import.meta.url);
  for (const file of (await readdir(migrations)).filter(name => name.endsWith(".sql")).sort())
    db.exec(await readFile(new URL(file, migrations), "utf8"));
  const statement = (sql, args = []) => ({
    bind(...values) { return statement(sql, values); },
    async first() { return db.prepare(sql).get(...args) ?? null; },
    async all() { return { results: db.prepare(sql).all(...args), meta: {} }; },
    async run() { const result = db.prepare(sql).run(...args); return { results: [], meta: { changes: Number(result.changes) } }; },
    execute() { const result = db.prepare(sql).run(...args); return { results: [], meta: { changes: Number(result.changes) } }; },
  });
  const DB = { prepare: statement, async batch(statements) {
    db.exec("BEGIN IMMEDIATE");
    try { const result = statements.map(s => s.execute()); db.exec("COMMIT"); return result; }
    catch (error) { db.exec("ROLLBACK"); throw error; }
  } };
  await writeFile(join(state, "package.json"), '{"type":"module"}');
  for (const name of ["worker", "external-mcp", "share"]) {
    const source = (await readFile(new URL(`../src/${name}.ts`, import.meta.url), "utf8"))
      .replace('"./push-dispatch.js"', JSON.stringify(new URL("../src/push-dispatch.js", import.meta.url).href)).replace('"./single-activity.js"', JSON.stringify(new URL("../src/single-activity.js", import.meta.url).href));
    await writeFile(join(state, `${name}.js`), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText);
  }
  const { default: handler } = await import(pathToFileURL(join(state, "worker.js")).href);
  fetchWorker = async (url, options) => handler.fetch(new Request(url, options), { DB });
  return db;
}

test("encrypted usage is isolated, monotonic, replace-only, domain-separated and immediately revocable", async (context) => {
  const state = await mkdtemp(join(tmpdir(), "ammo-usage-http-"));
  let worker, db;
  context.after(async () => { if (worker) await stop(worker); if (db) db.close(); await rm(state, { recursive: true, force: true }); });
  const base = ["DB", "--local", "--persist-to", state, "--config", "workers/lite/wrangler.jsonc"];
  if (inProcess) db = await sqliteWorker(state);
  const sql = async (text) => db ? db.exec(text) : run(["d1", "execute", ...base, "--command", text], state);
  if (!inProcess) await run(["d1", "migrations", "apply", ...base], state);
  await sql(`INSERT INTO workspaces VALUES ('usage-ws','usage-mac','usage-epoch','${sourceKey}','2026-01-01T00:00:00Z'),('other-ws','other-mac','other-epoch','${sourceKey}','2026-01-01T00:00:00Z');
    INSERT INTO devices (device_id,workspace_id,role,name,token_hash,created_at) VALUES
    ('usage-mac','usage-ws','writer','Mac','${await hash(writerToken)}','2026-01-01T00:00:00Z'),
    ('usage-phone','usage-ws','viewer','Phone','${await hash(viewerToken)}','2026-01-01T00:00:00Z'),
    ('other-phone','other-ws','viewer','Other','${await hash(otherToken)}','2026-01-01T00:00:00Z'),
    ('rogue-mac','usage-ws','writer','Unpinned Mac','${await hash(rogueToken)}','2026-01-01T00:00:00Z');`);
  if (!inProcess) {
  worker = command(["dev", "--local", "--persist-to", state, "--port", String(port), "--config", "workers/lite/wrangler.jsonc"], state);
  let ready = false;
  for (let attempt = 0; attempt < 300; attempt++) {
    try { if ((await fetchWorker(`http://127.0.0.1:${port}/v1/capabilities`, { signal: AbortSignal.timeout(1000) })).ok) { ready = true; break; } } catch {}
    if (worker.child.exitCode !== null) assert.fail(worker.output());
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(ready, true, worker.output());
  }
  const put = (body, token = writerToken) => request("/v1/usage", options("PUT", token, body));
  const get = (token = viewerToken) => request("/v1/usage", options("GET", token));
  assert.equal((await request("/v1/usage")).status, 401);
  assert.equal((await get(writerToken)).status, 403);
  assert.equal((await get()).status, 404);
  const first = await envelope(1);
  assert.equal((await put(first, viewerToken)).status, 403);
  assert.equal((await put(await envelope(1, { fields: { sourceDeviceId: "rogue-mac" } }), rogueToken)).status, 403);
  assert.equal((await put(await envelope(1, { fields: { workspaceId: "other-ws" } }))).status, 403);
  assert.equal((await put(await envelope(1, { fields: { sourceEpoch: "wrong-epoch" } }))).status, 403);
  assert.equal((await put({ ...first, unknown: true })).status, 400);
  assert.equal((await put({ ...first, schemaVersion: "2.0.0" })).status, 400);
  assert.equal((await put({ ...first, signature: encoded(Buffer.alloc(64)) })).status, 403);
  // A valid quota signature can never be replayed as usage, or vice versa.
  const quota = await envelope(1, { domain: "QI" });
  assert.equal((await put(quota)).status, 403);
  assert.equal((await request("/v1/snapshot", options("PUT", writerToken, first))).status, 403);
  const quotaReceipt = await request("/v1/snapshot", options("PUT", writerToken, quota));
  assert.equal(quotaReceipt.status, 200);
  const accepted = await put(first); assert.equal(accepted.status, 200);
  const retries = await Promise.all([put(first), put(first)]);
  for (const retry of retries) { assert.equal(retry.status, 200); assert.deepEqual(retry.body, accepted.body); }
  assert.equal((await put(await envelope(1))).status, 409);
  assert.equal((await get(otherToken)).status, 404);
  const initial = await get(); assert.deepEqual(initial.body.envelope, first);
  const read = await fetchWorker(`http://127.0.0.1:${port}/v1/usage`, options("GET", viewerToken));
  const etag = read.headers.get("etag"); await read.arrayBuffer();
  const cached = await fetchWorker(`http://127.0.0.1:${port}/v1/usage`, { headers: { authorization: `Bearer ${viewerToken}`, "if-none-match": etag } });
  assert.equal(cached.status, 304);
  const second = await envelope(2, { tokens: 250 }); assert.equal((await put(second)).status, 200);
  const replaced = await get(); assert.equal((await open(replaced.body.envelope)).buckets[0].tokens.nonCachedInput, 250);
  assert.equal((await put(first)).status, 409);
  assert.deepEqual((await request("/v1/snapshot", options("GET", viewerToken))).body.envelope, quota);
  const concurrent = await Promise.all([put(await envelope(3)), put(await envelope(4))]);
  assert.equal(concurrent[1].status, 200); assert.ok([200, 409].includes(concurrent[0].status));
  assert.equal((await get()).body.envelope.sequence, 4);
  // Both the body stream and decoded ciphertext are independently bounded.
  assert.equal((await put(await envelope(5, { bytes: Buffer.alloc(131073, 120) }))).status, 413);
  assert.equal((await request("/v1/usage", options("PUT", writerToken, { padding: "x".repeat(262145) }))).status, 413);
  const latest = await envelope(5, { bytes: Buffer.alloc(131072, 120) });
  const latestReceipt = await put(latest); assert.equal(latestReceipt.status, 200);
  // Retiring old ciphertext does not reset the replay watermark or refresh TTL.
  await sql("UPDATE usage_snapshots SET expires_at = '2000-01-01T00:00:00Z' WHERE workspace_id = 'usage-ws'");
  assert.equal((await get()).status, 404);
  assert.deepEqual((await put(latest)).body, latestReceipt.body);
  assert.equal((await get()).status, 404);
  assert.equal((await put(second)).status, 409);
  assert.equal((await put(await envelope(6))).status, 200);
  await sql("UPDATE devices SET revoked_at = '2026-01-01T00:00:00Z' WHERE device_id = 'usage-phone'");
  const revokedCache = await fetchWorker(`http://127.0.0.1:${port}/v1/usage`, { headers: { authorization: `Bearer ${viewerToken}`, "if-none-match": etag } });
  assert.equal(revokedCache.status, 401); await revokedCache.arrayBuffer();
  await sql("UPDATE workspaces SET source_epoch = 'new-epoch' WHERE workspace_id = 'usage-ws'");
  assert.equal((await put(await envelope(7))).status, 403);
  assert.equal((await put(await envelope(1, { fields: { sourceEpoch: "new-epoch" } }))).status, 200);
  await sql("UPDATE devices SET revoked_at = '2026-01-01T00:00:00Z' WHERE device_id = 'usage-mac'");
  assert.equal((await put(await envelope(2, { fields: { sourceEpoch: "new-epoch" } }))).status, 401);
});
