import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
// In-process dispatchFetch runs the actual workerd runtime and D1 binding locally.
// Only synthetic identities, ciphertext and the committed migrations are used.
test('workerd + D1 v2 HTTP CAS, migration triggers, source binding and v1 compatibility', async (t) => {
    const result = await build({ entryPoints: [new URL('../src/worker.ts', import.meta.url).pathname], bundle: true, write: false, format: 'esm', platform: 'browser', target: 'es2022' });
    const mf = new Miniflare(convertV4MiniflareOptions({ name: "v2", modules: true, script: result.outputFiles[0].text, compatibilityDate: '2026-06-10', d1Databases: ['DB'], bindings: { DELIVERY_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString('base64url') } }));
    t.after(() => mf.dispose());
    const db = await mf.getD1Database('DB');
    for (const name of (await readdir(new URL('../migrations/', import.meta.url))).filter(x => x.endsWith('.sql')).sort()) {
        const migration = await readFile(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
        let statement = '';
        for (const line of migration.split('\n')) {
            if (line.trim().startsWith('--'))
                continue;
            statement += line + '\n';
            if (line.trim().endsWith(';') && (!/^\s*CREATE TRIGGER/i.test(statement) || line.trim() === 'END;')) {
                await db.prepare(statement).run();
                statement = '';
            }
        }
    }
    const now = new Date().toISOString(), hash = s => createHash('sha256').update(s).digest('hex');
    const viewer = 'synthetic-workerd-viewer-token-00001', writer = 'synthetic-workerd-writer-token-00001';
    await db.batch([
        db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?)').bind('ws', 'mac', 'epoch', 'synthetic', now),
        db.prepare('INSERT INTO devices(device_id,workspace_id,role,name,token_hash,created_at) VALUES(?,?,?,?,?,?)').bind('mac', 'ws', 'writer', 'synthetic', hash(writer), now),
        db.prepare('INSERT INTO devices(device_id,workspace_id,role,name,token_hash,created_at) VALUES(?,?,?,?,?,?)').bind('phone', 'ws', 'viewer', 'synthetic', hash(viewer), now)
    ]);
    const request = async (path, method = 'GET', body, token = viewer) => {
        const r = await mf.dispatchFetch(`https://local.test${path}`, { method, headers: { authorization: `Bearer ${token}` }, ...(body ? { body: JSON.stringify(body) } : {}) });
        return { status: r.status, body: await r.json() };
    };
    assert.deepEqual((await request('/v1/capabilities')).body.activityContentVersions, [1, 2]);
    const body = { expectedDisplayRevision: 0, expectedRegistrationRevision: 0, commandId: 'create', windowIds: ['A', 'B'], sourceDeviceId: 'mac', sourceEpoch: 'epoch', activityToken: 'synthetic-activity-token', environment: 'sandbox', endsAt: new Date(Date.now() + 7 * 3600000).toISOString(), coverageExpiresAt: new Date(Date.now() + 3 * 3600000).toISOString(), projectionConsent: true };
    const races = await Promise.all([request('/v2/activities/group', 'PUT', body), request('/v2/activity-display', 'PUT', { expectedDisplayRevision: 0, commandId: 'stop', action: 'stop' })]);
    assert.deepEqual(races.map(x => x.status).sort(), [200, 409]);
    let state = (await request('/v2/activity-display')).body;
    if (state.stopped) {
        body.expectedDisplayRevision = state.displayRevision;
        body.commandId = 'fresh';
        assert.equal((await request('/v2/activities/group', 'PUT', body)).status, 200);
        state = (await request('/v2/activity-display')).body;
    }
    const before = await db.prepare('SELECT bundle_revision FROM live_activity_groups WHERE group_id=?').bind('group').first();
    const projection = { windowId: 'A', sequence: 3, label: 'Synthetic', remainingBps: 4500, displayState: 'fresh', observedAt: now, staleAt: new Date(Date.now() + 60000).toISOString(), resetsAt: null };
    assert.equal((await request('/v1/live-projections', 'PUT', projection, writer)).status, 200);
    const queued = await db.prepare('SELECT * FROM live_activity_groups WHERE group_id=?').bind('group').first();
    assert.equal(queued.bundle_revision, before.bundle_revision + 1);
    assert.equal(JSON.parse(queued.claimed_json)[0].remainingBps, 4500);
    assert.equal(JSON.parse(queued.claimed_json)[1].displayState, 'unavailable');
    assert.ok(queued.pending_revision, 'unconfigured APNs keeps pending');
    assert.equal((await request('/v1/activities/legacy', 'PUT', { windowId: 'A', activityToken: 'synthetic-v1-token', environment: 'sandbox', endsAt: new Date(Date.now() + 3600000).toISOString(), projectionConsent: true })).status, 200);
    assert.equal((await request('/v2/activity-display', 'PUT', { expectedDisplayRevision: state.displayRevision, commandId: 'abandon', action: 'abandon' })).status, 200);
    assert.equal((await request('/v2/activities/group', 'PUT', body)).status, 409);
    assert.equal((await request('/v2/activity-display')).body.stopped, true);
});
