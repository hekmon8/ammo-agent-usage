import assert from "node:assert/strict";
import { KeyObject } from "node:crypto";
import { readFile, mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test, { after } from "node:test";
import ts from "typescript";

// Import the actual Worker handler with an injected D1/PushTransport. The HTTP
// suite separately exercises tenant/role authorization against local workerd D1.
const modules = await mkdtemp(join(tmpdir(), "qi-worker-modules-"));
after(() => rm(modules, { recursive: true, force: true }));
await writeFile(join(modules, "package.json"), JSON.stringify({ type: "module" }));
for (const name of ["worker", "external-mcp", "share"]) {
  const source = (await readFile(new URL(`../src/${name}.ts`, import.meta.url), "utf8"))
    .replace('"./push-dispatch.js"', JSON.stringify(new URL("../src/push-dispatch.js", import.meta.url).href)).replace('"./single-activity.js"', JSON.stringify(new URL("../src/single-activity.js", import.meta.url).href));
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
  await writeFile(join(modules, `${name}.js`), compiled);
}
const { registerActivity, putProjection, flushPending, reconcilePending, ApnsTransport, default: worker } = await import(pathToFileURL(join(modules, "worker.js")).href);
const { manageMCP } = await import(pathToFileURL(join(modules, "external-mcp.js")).href);

test("APNs provider JWT is encrypted and shared across concurrent sends, expiry, and key rotation", async () => {
  const rows = new Map(); let claims = 0;
  const DB = { prepare(sql) {
    let args;
    return { bind(...values) { args = values; return this; }, async first() {
      if (!sql.startsWith("SELECT token_ciphertext, issued_at_ms")) throw new Error("Unexpected cache read");
      return rows.get(args[0]) ?? null;
    }, async run() {
      if (sql.startsWith("INSERT INTO apns_provider_token_cache")) {
        const row = rows.get(args[0]);
        if (row && (row.lease_until_ms ?? 0) > args[3] || row && row.issued_at_ms !== null && row.issued_at_ms > args[4] && row.issued_at_ms <= args[5]) return { meta: { changes: 0 } };
        rows.set(args[0], { token_ciphertext: row?.token_ciphertext ?? null, issued_at_ms: row?.issued_at_ms ?? null, lease_id: args[1], lease_until_ms: args[2] });
        claims++;
      } else if (sql.startsWith("UPDATE apns_provider_token_cache SET token_ciphertext = ?, issued_at_ms")) {
        const row = rows.get(args[2]);
        if (!row || row.lease_id !== args[3]) return { meta: { changes: 0 } };
        Object.assign(row, { token_ciphertext: args[0], issued_at_ms: args[1], lease_id: null, lease_until_ms: null });
      } else if (sql.startsWith("UPDATE apns_provider_token_cache SET token_ciphertext = NULL")) {
        const row = rows.get(args[0]);
        if (row?.token_ciphertext === args[1]) Object.assign(row, { token_ciphertext: null, issued_at_ms: null });
      } else if (sql.startsWith("UPDATE apns_provider_token_cache SET lease_id = NULL")) {
        const row = rows.get(args[0]); if (row?.lease_id === args[1]) Object.assign(row, { lease_id: null, lease_until_ms: null });
      } else throw new Error("Unexpected cache mutation");
      return { meta: { changes: 1 } };
    } };
  } };
  const key = async () => {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    return KeyObject.from(pair.privateKey).export({ type: "pkcs8", format: "pem" });
  };
  const env = { DB, DELIVERY_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64url"), APNS_TEAM_ID: "TEAM", APNS_KEY_ID: "KEY", APNS_PRIVATE_KEY: await key(), APNS_TOPIC: "example.app" };
  const originalFetch = globalThis.fetch, authorization = [];
  globalThis.fetch = async (_url, init) => { authorization.push(init.headers.authorization); return new Response(null, { status: 200 }); };
  try {
    const send = () => new ApnsTransport(env).send("device-token", "sandbox", { aps: {} });
    assert.deepEqual((await Promise.all(Array.from({ length: 8 }, send))).map(result => result.status), Array(8).fill(200));
    assert.equal(new Set(authorization).size, 1);
    assert.equal(claims, 1);
    assert.equal(rows.size, 1);
    assert.equal([...rows.values()][0].token_ciphertext.includes(authorization[0].slice(7)), false);
    [...rows.values()][0].issued_at_ms = Date.now() - 46 * 60_000;
    await send();
    assert.equal(claims, 2);
    env.APNS_PRIVATE_KEY = await key();
    await send();
    assert.equal(claims, 3);
    assert.equal(rows.size, 2);
    assert.notEqual(authorization.at(-1), authorization.at(-2));
    env.DELIVERY_ENCRYPTION_KEY = Buffer.alloc(32, 8).toString("base64url");
    assert.equal(await send(), null, "an unreadable fresh cache must not sign an early replacement");
    assert.equal(claims, 3);
    assert.equal(authorization.length, 10);
    const brokenDb = { ...env, DB: { prepare() { throw new Error("D1 unavailable"); } } };
    assert.equal(await new ApnsTransport(brokenDb).send("device-token", "sandbox", { aps: {} }), null);
    assert.equal(authorization.length, 10, "D1 failures must not send with an uncached JWT");
  } finally { globalThis.fetch = originalFetch; }
});

test("unknown routes do not write D1 and resource IDs share one rate bucket", async () => {
  const buckets = new Map(); let writes = 0;
  const env = { DB: { prepare(sql) {
    let args;
    return { bind(...values) { args = values; return this; }, async run() {
      writes++;
      if (sql.startsWith("INSERT INTO rate_limits")) { if (!buckets.has(args[0])) buckets.set(args[0], 0); return { meta: { changes: 1 }, results: [] }; }
      if (sql.startsWith("UPDATE rate_limits SET count")) {
        const count = buckets.get(args[2]); if (count >= 30) return { meta: { changes: 0 }, results: [] };
        buckets.set(args[2], count + 1);
      }
      return { meta: { changes: 1 }, results: [] };
    } };
  } } };
  for (let n = 0; n < 50; n++) assert.equal((await worker.fetch(new Request(`https://quota.example.invalid/random-${n}`), env)).status, 404);
  for (let n = 0; n < 50; n++) assert.equal((await worker.fetch(new Request("https://quota.example.invalid/v1/pairings", { method: `CUSTOM${n}` }), env)).status, 404);
  for (const [method, path] of [["GET", "/v1/bootstrap"], ["POST", "/v1/snapshot"], ["GET", "/v1/pairings/id/approve"], ["POST", "/v1/shares/id/result"], ["GET", "/v1/activities/id"]])
    assert.equal((await worker.fetch(new Request(`https://quota.example.invalid${path}`, { method }), env)).status, 404);
  assert.equal((await worker.fetch(new Request("https://quota.example.invalid/mcp"), env)).status, 405);
  assert.equal(writes, 0);
  for (let n = 0; n < 31; n++) {
    const response = await worker.fetch(new Request(`https://quota.example.invalid/v1/pairings/random_${n}/result`), env);
    assert.equal(response.status, n < 30 ? 401 : 429);
  }
  assert.equal(buckets.size, 1);
});

function fixture() {
  let activity;
  let storedProjection;
  const updates = [];
  const DB = {
    async batch(statements) { return Promise.all(statements.map(statement => statement.run())); },
    prepare(sql) {
      let args;
      return {
        bind(...values) { args = values; return this; },
        async first() {
          if (sql.startsWith("SELECT workspace_id")) return { workspace_id: "workspace", source_epoch: "epoch" };
          if (sql.startsWith("SELECT sequence, projection_json")) return storedProjection ? { sequence: storedProjection.sequence, projection_json: storedProjection.json } : null;
          throw new Error("Unexpected read");
        },
        async run() {
          if (sql.startsWith("INSERT INTO live_activities")) {
            activity = { activity_id: args[0], device_id: args[2], window_id: args[3], token_ciphertext: args[4], environment: args[5], ends_at: args[6], last_sent_at: null, backoff_until: null };
          } else if (sql.startsWith("UPDATE live_activities SET pending_sequence = CASE")) {
            activity.pending_sequence = storedProjection?.sequence ?? null;
          } else if (sql.startsWith("INSERT INTO live_projections")) {
            storedProjection = { sequence: args[3], json: args[4] };
          } else if (sql.startsWith("UPDATE live_activities SET pending_sequence = ?")) {
            if (activity) activity.pending_sequence = args[0];
          } else if (sql.startsWith("SELECT activity.activity_id")) {
            const ready = activity && activity.pending_sequence && (!activity.backoff_until || Date.parse(activity.backoff_until) <= Date.now()) && (!activity.last_sent_at || Date.parse(activity.last_sent_at) + 300000 <= Date.now());
            return { results: ready ? [{ ...activity, projection_json: storedProjection.json }] : [], meta: {} };
          } else if (sql.startsWith("UPDATE live_activities SET dispatch_lease")) {
            if (!activity || activity.pending_sequence !== args[3]) return { results: [], meta: { changes: 0 } };
            activity.dispatch_lease = args[0]; activity.dispatching_until = args[1];
          } else if (sql.startsWith("UPDATE live_activities SET last_sent_at")) {
            activity.last_sent_at = args[0]; activity.pending_sequence = activity.pending_sequence === args[1] ? null : activity.pending_sequence;
            activity.dispatch_lease = null; activity.dispatching_until = null;
            updates.push(sql);
          } else if (sql.startsWith("UPDATE live_activities SET disabled_at")) {
            activity.disabled_at = args[0]; activity.pending_sequence = null;
            updates.push(sql);
          } else if (sql.startsWith("UPDATE live_activities SET backoff_until")) {
            activity.backoff_until = args[0];
            updates.push(sql);
          } else throw new Error("Unexpected mutation");
          return { results: [], meta: { changes: 1 } };
        }
      };
    }
  };
  const env = { DB, DELIVERY_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64url") };
  const viewer = { device_id: "viewer", workspace_id: "workspace", role: "viewer", token_hash: "synthetic" };
  const writer = { device_id: "writer", workspace_id: "workspace", role: "writer", token_hash: "synthetic" };
  const now = Date.now();
  const endsAt = new Date(now + 300_000).toISOString();
  const data = { windowId: "window", sequence: 1, label: "claude · weekly", remainingBps: 4200, displayState: "fresh", observedAt: new Date(now - 1000).toISOString(), staleAt: new Date(now + 600_000).toISOString(), resetsAt: null };
  const request = (body) => new Request("https://quota.example.invalid/v1/test", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return { env, viewer, writer, endsAt, data, request, updates, activity: () => activity, clearBackoff: () => { activity.backoff_until = null; }, clearCooldown: () => { activity.last_sent_at = new Date(Date.now() - 301000).toISOString(); } };
}

test("registered encrypted Activity token reaches transport with native numeric timestamps", async () => {
  const f = fixture();
  const registration = await registerActivity(f.request({ windowId: "window", activityToken: "synthetic-token", environment: "sandbox", endsAt: f.endsAt, projectionConsent: true }), f.env, f.viewer, "activity");
  assert.equal(registration.status, 200);
  assert.equal(f.activity().token_ciphertext.includes("synthetic-token"), false);
  let sent;
  const response = await putProjection(f.request(f.data), f.env, f.writer, { async send(token, environment, payload) {
    assert.equal(token, "synthetic-token"); assert.equal(environment, "sandbox"); sent = payload; return { status: 200 };
  } });
  assert.equal(response.status, 200);
  assert.equal(sent.aps["content-state"].remainingBps, 4200);
  assert.equal(sent.aps["content-state"].observedAt, Math.floor(Date.parse(f.data.observedAt) / 1000));
  assert.equal(sent.aps["content-state"].resetsAt, null);
  assert.equal(sent.aps["stale-date"], Math.floor(Date.parse(f.endsAt) / 1000));
  assert.equal("windowId" in sent.aps["content-state"], false);
  assert.equal(f.updates.some((sql) => sql.includes("last_sent_at")), true);
});

test("Activity token corruption cannot dispatch and wrong role cannot publish", async () => {
  const f = fixture();
  await registerActivity(f.request({ windowId: "window", activityToken: "synthetic-token", environment: "sandbox", endsAt: f.endsAt, projectionConsent: true }), f.env, f.viewer, "activity");
  f.activity().token_ciphertext = "invalid";
  const transport = { async send() { assert.fail("Corrupt token dispatched"); } };
  const denied = await putProjection(f.request(f.data), f.env, f.viewer, transport);
  assert.equal(denied.status, 403);
  const unavailable = await putProjection(f.request(f.data), f.env, f.writer, transport);
  assert.equal(unavailable.status, 200);
  assert.equal(f.activity().disabled_at !== undefined, true);
});

test("failed APNs dispatch stays pending; same-content retry and scheduled flush deliver it", async () => {
  const f = fixture();
  await registerActivity(f.request({ windowId: "window", activityToken: "synthetic-token", environment: "sandbox", endsAt: f.endsAt, projectionConsent: true }), f.env, f.viewer, "activity");
  const unavailable = await putProjection(f.request(f.data), f.env, f.writer, { async send() { return null; } });
  assert.equal(unavailable.status, 200);
  assert.equal(f.activity().pending_sequence, 1);
  assert.ok(f.activity().backoff_until);
  const conflicting = await putProjection(f.request({ ...f.data, remainingBps: 100 }), f.env, f.writer, { async send() { assert.fail("Conflict dispatched"); } });
  assert.equal(conflicting.status, 409);
  const retry = await putProjection(f.request(f.data), f.env, f.writer, { async send() { assert.fail("Backoff bypassed"); } });
  assert.equal(retry.status, 200);
  f.clearBackoff();
  let sends = 0;
  await flushPending(f.env, { async send() { sends++; return { status: 200 }; } });
  assert.equal(sends, 1);
  assert.equal(f.activity().pending_sequence, null);
  const next = await putProjection(f.request({ ...f.data, sequence: 2 }), f.env, f.writer, { async send() { assert.fail("Cooldown bypassed"); } });
  assert.equal(next.status, 200);
  assert.equal(f.activity().pending_sequence, 2);
  f.clearCooldown();
  await flushPending(f.env, { async send() { sends++; return { status: 200 }; } });
  assert.equal(sends, 2);
  assert.equal(f.activity().pending_sequence, null);
});

test("concurrent same-sequence projection PUT accepts only matching committed content", async () => {
  for (const conflicting of [false, true]) {
    const f = fixture(); let reads = 0; let committed;
    const DB = { async batch(statements) { return Promise.all(statements.map(statement => statement.run())); }, prepare(sql) {
      let args;
      return { bind(...values) { args = values; return this; }, async first() {
        if (sql.startsWith("SELECT workspace_id")) return { workspace_id: "workspace", source_epoch: "epoch" };
        if (sql.startsWith("SELECT sequence, projection_json")) return ++reads === 1 ? null : committed;
        throw new Error("Unexpected read");
      }, async run() {
        if (sql.startsWith("INSERT INTO live_projections")) {
          committed = { sequence: args[3], projection_json: conflicting ? JSON.stringify({ ...JSON.parse(args[4]), label: "other" }) : args[4] };
          return { results: [], meta: { changes: 0 } };
        }
        if (sql.startsWith("UPDATE live_activities SET pending_sequence")) return { results: [], meta: { changes: 0 } };
        if (sql.startsWith("SELECT activity.activity_id")) return { results: [], meta: { changes: 0 } };
        throw new Error("Unexpected mutation");
      } };
    } };
    const response = await putProjection(f.request(f.data), { ...f.env, DB }, f.writer, { async send() { assert.fail("No activity to send"); } });
    assert.equal(response.status, conflicting ? 409 : 200);
    assert.equal(reads, 2);
  }
});

test("concurrent same-sequence MCP PUT accepts only matching committed content", async () => {
  for (const conflicting of [false, true]) {
    let reads = 0; let committed;
    const env = { DB: { prepare(sql) {
      let args;
      return { bind(...values) { args = values; return this; }, async first() {
        if (sql.startsWith("SELECT source_epoch")) return { source_epoch: "epoch" };
        if (sql.startsWith("SELECT source_sequence, snapshot_json")) return ++reads === 1 ? { source_sequence: 0, snapshot_json: null } : committed;
        throw new Error("Unexpected read");
      }, async run() {
        if (!sql.startsWith("UPDATE mcp_access SET snapshot_json")) throw new Error("Unexpected mutation");
        committed = { source_sequence: args[1], snapshot_json: conflicting ? JSON.stringify({ ...JSON.parse(args[0]), capturedAt: "2000-01-01T00:00:00.000Z" }) : args[0] };
        return { results: [], meta: { changes: 0 } };
      } };
    } } };
    const writer = { device_id: "writer", workspace_id: "workspace", role: "writer", token_hash: "synthetic" };
    const body = { sourceEpoch: "epoch", sequence: 1, capturedAt: new Date().toISOString(), windows: [] };
    const request = new Request("https://quota.example.invalid/v1/mcp-snapshot", { method: "PUT", body: JSON.stringify(body) });
    const response = await manageMCP(request, env, writer);
    assert.equal(response.status, conflicting ? 409 : 200);
    assert.equal(reads, 2);
  }
});

test("APNs expired token is disabled and never classified as delivery", async () => {
  const f = fixture();
  await registerActivity(f.request({ windowId: "window", activityToken: "synthetic-token", environment: "sandbox", endsAt: f.endsAt, projectionConsent: true }), f.env, f.viewer, "activity");
  await putProjection(f.request(f.data), f.env, f.writer, { async send() { return { status: 410 }; } });
  assert.equal(f.updates.some((sql) => sql.includes("disabled_at")), true);
  assert.equal(f.updates.some((sql) => sql.includes("last_sent_at")), false);
});
