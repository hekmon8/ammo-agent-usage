import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFile, readdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import test, { after } from 'node:test';
import ts from 'typescript';
import { flushV2, buildV2Payload } from '../src/single-activity.js';
const directory = await mkdtemp(join(tmpdir(), 'ammo-v2-sqlite-'));
after(() => rm(directory, { recursive: true, force: true }));
await writeFile(join(directory, 'package.json'), '{"type":"module"}');
for (const name of ['worker', 'external-mcp', 'share']) {
    let source = await readFile(new URL(`../src/${name}.ts`, import.meta.url), 'utf8');
    for (const dependency of ['push-dispatch', 'single-activity'])
        source = source.replace(`"./${dependency}.js"`, JSON.stringify(new URL(`../src/${dependency}.js`, import.meta.url).href));
    await writeFile(join(directory, `${name}.js`), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText);
}
const { default: worker, decryptActivityToken, putProjection } = await import(pathToFileURL(join(directory, 'worker.js')).href);
const credential = s => 'synthetic-test-token-000000000000-' + s;
const hash = s => createHash('sha256').update(s).digest('hex');
let command = 0;
const at = offset => new Date(Date.now() + offset).toISOString();
async function fixture(t, { migration = true } = {}) {
    const db = new DatabaseSync(':memory:');
    t.after(() => db.close());
    for (const name of (await readdir(new URL('../migrations/', import.meta.url))).filter(x => x.endsWith('.sql') && (migration || !x.startsWith('0015'))).sort())
        db.exec(await readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8'));
    db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?)').run('ws', 'mac', 'epoch', 'synthetic-key', at(0));
    db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?)').run('other-ws', 'other-mac', 'other-epoch', 'synthetic-key', at(0));
    for (const [device, ws, role] of [['mac', 'ws', 'writer'], ['phone', 'ws', 'viewer'], ['other', 'other-ws', 'viewer']])
        db.prepare('INSERT INTO devices(device_id,workspace_id,role,name,token_hash,created_at) VALUES(?,?,?,?,?,?)').run(device, ws, role, 'Synthetic', hash(credential(device)), at(0));
    const statement = (sql, args = []) => ({ bind(...v) { return statement(sql, v); }, async first() { return db.prepare(sql).get(...args) ?? null; }, async all() { return { results: db.prepare(sql).all(...args), meta: {} }; }, async run() { return this.execute(); }, execute() { const s = db.prepare(sql); if (s.columns().length)
            return { results: s.all(...args), meta: { changes: 0 } }; const r = s.run(...args); return { results: [], meta: { changes: Number(r.changes) } }; } });
    const env = { DB: { prepare: statement, async batch(statements) { db.exec('BEGIN IMMEDIATE'); try {
                const r = statements.map(s => s.execute());
                db.exec('COMMIT');
                return r;
            }
            catch (e) {
                db.exec('ROLLBACK');
                throw e;
            } } }, DELIVERY_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString('base64url') };
    let requestNumber = 0;
    const request = async (path, method = 'GET', body, device = 'phone') => {
        const response = await worker.fetch(new Request(`https://synthetic.test${path}`, { method, headers: { authorization: `Bearer ${credential(device)}`, 'cf-connecting-ip': `test-${++requestNumber}` }, ...(body ? { body: JSON.stringify(body) } : {}) }), env);
        return { status: response.status, body: await response.json() };
    };
    const body = (extra = {}) => ({ expectedDisplayRevision: 0, expectedRegistrationRevision: 0, commandId: `c-${++command}`, windowIds: ['A', 'B'], sourceDeviceId: 'mac', sourceEpoch: 'epoch', activityToken: 'synthetic-token', environment: 'sandbox', endsAt: at(7 * 3600000), coverageExpiresAt: at(3 * 3600000), projectionConsent: true, ...extra });
    const register = (b = body(), group = 'group') => request(`/v2/activities/${group}`, 'PUT', b);
    const stop = (revision = 0, action = 'stop', commandId = `c-${++command}`) => request('/v2/activity-display', 'PUT', { expectedDisplayRevision: revision, action, commandId });
    const project = (window, seq, epoch = 'epoch') => {
        const p = { windowId: window, sequence: seq, label: 'Private alias is stripped', remainingBps: seq * 100, displayState: 'fresh', observedAt: at(-1000), staleAt: at(60000), resetsAt: at(3600000) };
        db.prepare('INSERT INTO live_projections VALUES(?,?,?,?,?,?) ON CONFLICT(workspace_id,window_id) DO UPDATE SET source_epoch=excluded.source_epoch,sequence=excluded.sequence,projection_json=excluded.projection_json').run('ws', window, epoch, seq, JSON.stringify(p), at(0));
        return p;
    };
    const group = () => db.prepare('SELECT * FROM live_activity_groups WHERE group_id=?').get('group');
    const flush = send => flushV2(env, { send }, decryptActivityToken);
    return { db, env, request, body, register, stop, project, group, flush };
}
test('capability is lazy and migration absence fails closed; auth, role and workspace isolation', async (t) => {
    const old = await fixture(t, { migration: false });
    assert.equal((await old.request('/v1/capabilities')).body.activityContentVersions, undefined);
    assert.equal((await old.register()).status, 503);
    const f = await fixture(t);
    assert.deepEqual((await f.request('/v1/capabilities')).body.activityContentVersions, [1, 2]);
    assert.equal((await f.request('/v2/activity-display', 'GET', undefined, 'invalid')).status, 401);
    assert.equal((await f.request('/v2/activity-display', 'GET', undefined, 'mac')).status, 403);
    assert.equal((await f.request('/v2/activities/group', 'PUT', f.body(), 'other')).status, 409);
    assert.equal((await f.register()).status, 200);
    assert.equal((await f.request('/v2/activities/group', 'DELETE', undefined, 'other')).status, 200);
    assert.equal(f.group().retired, 0);
});
test('durable stop and abandon fence unseen delayed creates; retries need identical hash and cannot resurrect replaced intent', async (t) => {
    for (const action of ['stop', 'abandon']) {
        const f = await fixture(t), late = f.body();
        assert.equal((await f.request('/v2/activity-display')).body.groupId, null);
        const commandId = `c-${++command}`;
        const receipt = await f.stop(0, action, commandId);
        assert.equal(receipt.status, 200);
        assert.equal(receipt.body.displayRevision, 1);
        assert.deepEqual(await f.stop(0, action, commandId), receipt);
        assert.equal((await f.register(late)).status, 409);
        const b = f.body({ expectedDisplayRevision: 1 });
        const first = await f.register(b);
        assert.equal(first.status, 200);
        assert.deepEqual(await f.register(b), first);
        assert.equal((await f.register({ ...b, activityToken: 'different' })).status, 409);
        assert.equal((await f.stop(0, action, commandId)).status, 409);
        assert.equal((await f.stop(2)).status, 200);
        assert.equal((await f.register(b)).status, 409);
    }
});
test('create/replace CAS, fixed ordered members/card/source and renewal token CAS', async (t) => {
    const f = await fixture(t), b = f.body();
    const results = await Promise.all([f.register(b), f.register({ ...b, commandId: `c-${++command}` }, 'rival')]);
    assert.deepEqual(results.map(x => x.status).sort(), [200, 409]);
    const renewal = { ...b, expectedDisplayRevision: 1, expectedRegistrationRevision: 1, commandId: `c-${++command}`, activityToken: 'rotated' };
    for (const extra of [{ windowIds: ['B', 'A'] }, { sourceEpoch: 'wrong' }, { endsAt: at(6 * 3600000) }])
        assert.equal((await f.register({ ...renewal, ...extra })).status, 409);
    const receipt = await f.register(renewal);
    assert.equal(receipt.status, 200);
    assert.equal(receipt.body.displayRevision, 1);
    assert.equal(receipt.body.registrationRevision, 2);
    assert.deepEqual(await f.register(renewal), receipt);
    assert.equal((await f.register({ ...renewal, commandId: `c-${++command}` })).status, 409);
    assert.equal((await f.register(f.body({ expectedDisplayRevision: 1 }), 'new')).status, 200);
    await f.request('/v2/activities/group', 'DELETE');
    assert.equal((await f.request('/v2/activity-display')).body.groupId, 'new');
    assert.equal(f.group().retired, 1);
});
test('full ordered independent rows, missing/epoch-mismatched rows unavailable, native fields only and earliest stale date', async (t) => {
    const f = await fixture(t);
    f.project('B', 7);
    f.project('A', 99, 'old-epoch');
    await f.register(f.body({ windowIds: ['B', 'A'] }));
    let payload;
    await f.flush(async (token, environment, p) => { assert.equal(token, 'synthetic-token'); assert.equal(environment, 'sandbox'); payload = p; return { status: 200 }; });
    const c = payload.aps['content-state'];
    assert.deepEqual(c.rows.map(x => [x.windowID, x.sequence, x.remainingBps]), [['B', 7, 700], ['A', 0, null]]);
    assert.equal(c.rows[1].displayState, 'unavailable');
    assert.equal(payload.aps['stale-date'], payload.aps.timestamp);
    assert.equal(JSON.stringify(payload).includes('alias'), false);
    assert.equal(f.group().pending_revision, null);
    const stale = buildV2Payload({ claimed_json: JSON.stringify([{ observedAt: 100, staleAt: 500, displayState: 'fresh' }, { observedAt: 200, staleAt: 300, displayState: 'fresh' }]), claimed_revision: 9, last_event_timestamp: 250, ends_at: new Date(1000000).toISOString() });
    assert.equal(stale.aps['stale-date'], 300);
});
test('real projection route queues v2; in-flight row mutation survives ack and immutable claimed JSON', async (t) => {
    const f = await fixture(t);
    await f.register();
    f.project('A', 1);
    f.project('B', 9);
    const before = f.group().pending_revision;
    await f.flush(async (_token, _env, payload) => { assert.equal(payload.aps['content-state'].bundleRevision, before); f.project('A', 2); assert.equal(payload.aps['content-state'].rows[0].sequence, 1); return { status: 200 }; });
    assert.equal(f.group().pending_revision, before + 1);
    assert.equal(f.group().lease_id, null);
    f.db.exec("UPDATE live_activity_groups SET last_sent_at=NULL,last_event_timestamp=0");
    await f.flush(async (_t, _e, p) => { assert.deepEqual(p.aps['content-state'].rows.map(x => x.sequence), [2, 9]); return { status: 200 }; });
    assert.equal(f.group().pending_revision, null);
    f.db.prepare('DELETE FROM live_projections WHERE window_id=?').run('B');
    assert.ok(f.group().pending_revision);
    // Execute unchanged Mac17 admission SQL, including projection triggers, through actual handler.
    const data = { windowId: 'A', sequence: 3, label: 'quota', remainingBps: 3500, displayState: 'fresh', observedAt: at(-1000), staleAt: at(60000), resetsAt: null };
    const result = await putProjection(new Request('https://synthetic/v1/live-projections', { method: 'PUT', body: JSON.stringify(data) }), f.env, { device_id: 'mac', workspace_id: 'ws', role: 'writer', token_hash: hash(credential('mac')) }, { send: async () => ({ status: 200 }) });
    assert.equal(result.status, 200);
});
test('old-token 410 and all old completions cannot damage renewed registration', async (t) => {
    for (const outcome of [200, 410, 429, 500]) {
        const f = await fixture(t), b = f.body();
        await f.register(b);
        f.project('A', 1);
        await f.flush(async () => { assert.equal((await f.register({ ...b, commandId: `c-${++command}`, expectedDisplayRevision: 1, expectedRegistrationRevision: 1, activityToken: 'new-token' })).status, 200); return { status: outcome }; });
        assert.equal(f.group().registration_revision, 2);
        assert.equal(f.group().disabled, 0);
        assert.ok(f.group().pending_revision);
        assert.equal(f.group().backoff_until, null);
    }
});
test('same-revision new lease rejects late success/410/backoff/decrypt failure completion', async (t) => {
    for (const outcome of [200, 410, 429, 'decrypt']) {
        const f = await fixture(t);
        await f.register();
        f.project('A', 1);
        const replaceLease = () => f.db.exec("UPDATE live_activity_groups SET lease_id='new-lease',lease_until='2099-01-01T00:00:00.000Z'");
        if (outcome === 'decrypt')
            await flushV2(f.env, { send: async () => { throw Error('must not send'); } }, async () => { replaceLease(); return null; });
        else
            await f.flush(async () => { replaceLease(); return { status: outcome }; });
        assert.equal(f.group().lease_id, 'new-lease');
        assert.equal(f.group().disabled, 0);
        assert.equal(f.group().backoff_until, null);
        assert.ok(f.group().pending_revision);
    }
});
test('final pre-send and completion fence stops, revocation and epoch reuse', async (t) => {
    for (const mutation of ['stop', 'revoke', 'epoch', 'consent']) {
        const f = await fixture(t), b = f.body();
        await f.register(b);
        f.project('A', 1);
        const change = async () => { if (mutation === 'stop')
            await f.stop(1);
        else if (mutation === 'revoke')
            f.db.exec("UPDATE devices SET revoked_at='now' WHERE device_id='phone'");
        else if (mutation === 'consent')
            f.db.exec('UPDATE live_activity_groups SET projection_consent=0');
        else
            f.db.exec("UPDATE workspaces SET source_epoch='new-epoch'"); };
        let sends = 0;
        await flushV2(f.env, { send: async () => { sends++; return { status: 200 }; } }, async (...args) => { await change(); return decryptActivityToken(...args); });
        assert.equal(sends, 0);
        if (mutation === 'epoch') {
            assert.equal((await f.register({ ...b, expectedDisplayRevision: 1, expectedRegistrationRevision: 1, commandId: `c-${++command}` })).status, 409);
            f.project('A', 100, 'new-epoch');
            await f.flush(async () => { sends++; return { status: 200 }; });
            assert.equal(sends, 0);
        }
    }
    const f = await fixture(t);
    await f.register();
    await f.flush(async () => { await f.stop(1); return { status: 200 }; });
    assert.equal(f.group().retired, 1);
    assert.ok(f.group().pending_revision);
});
test('lease expiry, coverage, cooldown, backoff and true-clock timestamp constrain dispatch', async (t) => {
    const f = await fixture(t);
    await f.register();
    let count = 0;
    await f.flush(async () => { count++; return { status: 429 }; });
    assert.equal(count, 1);
    await f.flush(async () => { count++; return { status: 200 }; });
    assert.equal(count, 1);
    f.db.exec('UPDATE live_activity_groups SET backoff_until=NULL');
    await f.flush(async () => { count++; return { status: 200 }; });
    assert.equal(count, 1, 'same second is not assigned a future timestamp');
    f.db.exec('UPDATE live_activity_groups SET last_event_timestamp=0');
    await f.flush(async () => { count++; return { status: 200 }; });
    assert.equal(count, 2);
    f.project('A', 4);
    await f.flush(async () => { count++; return { status: 200 }; });
    assert.equal(count, 2);
    f.db.exec("UPDATE live_activity_groups SET last_sent_at=NULL,last_event_timestamp=0,coverage_expires_at='2000-01-01T00:00:00.000Z'");
    await f.flush(async () => { count++; return { status: 200 }; });
    assert.equal(count, 2);
});
test('validation rejects duplicate/empty/oversize members, consent and noncanonical deadlines; UTF8 payload has envelope headroom', async (t) => {
    const f = await fixture(t);
    for (const extra of [{ windowIds: [] }, { windowIds: ['A', 'A'] }, { windowIds: ['A', 'B', 'C'] }, { windowIds: ['x'.repeat(81)] }, { projectionConsent: false }, { commandId: 123 }, { sourceEpoch: 123 }, { endsAt: '2099-01-01T00:00:00.000Z' }, { coverageExpiresAt: at(5 * 3600000) }, { endsAt: '2026-10-07' }])
        assert.equal((await f.register(f.body(extra))).status, 400);
    await f.register(f.body({ windowIds: ['A'.repeat(80), 'B'.repeat(80)] }));
    let bytes;
    await f.flush(async (_t, _e, p) => { bytes = Buffer.byteLength(JSON.stringify(p)); return { status: 200 }; });
    assert.ok(bytes < 2048);
    console.log(`v2 worst-ID unavailable-row APNs envelope bytes: ${bytes}`);
});
test('simultaneous identical command retries share one receipt and one revision', async (t) => {
    const f = await fixture(t), body = f.body();
    const results = await Promise.all([f.register(body), f.register(body)]);
    assert.equal(results[0].status, 200);
    assert.deepEqual(results[0], results[1]);
    assert.equal(f.group().registration_revision, 1);
    const stops = await Promise.all([f.stop(1, 'stop', 'same-stop'), f.stop(1, 'stop', 'same-stop')]);
    assert.equal(stops[0].status, 200);
    assert.deepEqual(stops[0], stops[1]);
});
