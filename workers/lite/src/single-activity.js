import { dispatchPush } from './push-dispatch.js';
const id = { test: value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(value) };
const iso = () => new Date().toISOString();
const active = `EXISTS(SELECT 1 FROM devices d WHERE d.workspace_id=g.workspace_id AND d.device_id=g.device_id AND d.role='viewer' AND d.revoked_at IS NULL)
 AND EXISTS(SELECT 1 FROM workspaces w WHERE w.workspace_id=g.workspace_id AND w.writer_device_id=g.source_device_id AND w.source_epoch=g.source_epoch AND EXISTS(SELECT 1 FROM devices writer WHERE writer.device_id=w.writer_device_id AND writer.workspace_id=w.workspace_id AND writer.role='writer' AND writer.revoked_at IS NULL))
 AND EXISTS(SELECT 1 FROM live_activity_display_state s WHERE s.workspace_id=g.workspace_id AND s.device_id=g.device_id AND s.group_id=g.group_id AND s.display_revision=g.display_revision AND s.stopped=0)
 AND g.retired=0 AND g.disabled=0 AND g.projection_consent=1`;
export async function v2Available(env) {
    try {
        const row = await env.DB.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name IN ('live_activity_groups','live_activity_group_windows','live_activity_display_state','live_activity_commands')").first();
        return row?.n === 4;
    }
    catch {
        return false;
    }
}
export function isV2Route(path) { return path === '/v2/activity-display' || /^\/v2\/activities\/[A-Za-z0-9_-]{1,80}$/.test(path); }
export async function handleV2(request, env, viewer, helpers) {
    const { json, problem, readJson, encryptStored } = helpers;
    if (viewer.role !== 'viewer')
        return problem(403, 'viewer_required');
    if (!await v2Available(env))
        return problem(503, 'activity_v2_unavailable');
    const ws = viewer.workspace_id, dev = viewer.device_id;
    const auth = `EXISTS(SELECT 1 FROM devices WHERE workspace_id=? AND device_id=? AND token_hash=? AND role='viewer' AND revoked_at IS NULL)`;
    const authArgs = [ws, dev, viewer.token_hash];
    const path = new URL(request.url).pathname, group = path.startsWith('/v2/activities/') ? path.split('/').pop() : null;
    await env.DB.prepare(`INSERT OR IGNORE INTO live_activity_display_state(workspace_id,device_id) SELECT ?,? WHERE ${auth}`).bind(ws, dev, ...authArgs).run();
    const state = await env.DB.prepare(`SELECT display_revision,group_id,stopped FROM live_activity_display_state WHERE workspace_id=? AND device_id=? AND ${auth}`).bind(ws, dev, ...authArgs).first();
    if (!state)
        return problem(401, 'invalid_credential');
    if (request.method === 'GET' && !group)
        return json({ displayRevision: state.display_revision, groupId: state.group_id, stopped: !!state.stopped });
    if (request.method === 'DELETE' && group) {
        // Resource cleanup never changes display intent; a later explicit CAS is still required.
        await env.DB.prepare(`UPDATE live_activity_groups SET retired=1,lease_id=NULL WHERE group_id=? AND workspace_id=? AND device_id=? AND ${auth}`).bind(group, ws, dev, ...authArgs).run();
        return json({ ok: true });
    }
    if (request.method !== 'PUT')
        return problem(405, 'method_not_allowed');
    const b = await readJson(request);
    if (!b || b === 'too_large')
        return problem(b === 'too_large' ? 413 : 400, 'invalid_request');
    const keys = group ? ['expectedDisplayRevision', 'expectedRegistrationRevision', 'commandId', 'windowIds', 'sourceDeviceId', 'sourceEpoch', 'activityToken', 'environment', 'endsAt', 'coverageExpiresAt', 'projectionConsent'] : ['expectedDisplayRevision', 'commandId', 'action'];
    if (Object.keys(b).some(k => !keys.includes(k)) || !Number.isSafeInteger(b.expectedDisplayRevision) || b.expectedDisplayRevision < 0 || !id.test(b.commandId ?? ''))
        return problem(400, 'invalid_request');
    if (!group && !['stop', 'abandon'].includes(b.action))
        return problem(400, 'invalid_request');
    if (group && (!Number.isSafeInteger(b.expectedRegistrationRevision) || b.expectedRegistrationRevision < 0 || !Array.isArray(b.windowIds) || b.windowIds.length < 1 || b.windowIds.length > 2 || new Set(b.windowIds).size !== b.windowIds.length || b.windowIds.some(x => typeof x !== 'string' || !id.test(x)) || !id.test(b.sourceDeviceId ?? '') || !id.test(b.sourceEpoch ?? '') || typeof b.activityToken !== 'string' || !b.activityToken.length || b.activityToken.length > 1024 || !['sandbox', 'production'].includes(b.environment) || b.projectionConsent !== true))
        return problem(400, 'invalid_request');
    const canonical = JSON.stringify([group, ...keys.map(k => b[k])]);
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical))), x => x.toString(16).padStart(2, '0')).join('');
    const replay = await env.DB.prepare('SELECT * FROM live_activity_commands WHERE workspace_id=? AND device_id=? AND command_id=?').bind(ws, dev, b.commandId).first();
    const receipt = c => ({ ok: true, displayRevision: c.display_revision, ...(c.group_id ? { registrationRevision: c.registration_revision } : {}), groupId: c.group_id, stopped: !c.group_id });
    // Re-read command and current intent in one SQL snapshot, including concurrent retries.
    const currentReceipt = async () => {
        const accepted = await env.DB.prepare(`SELECT c.* FROM live_activity_commands c JOIN live_activity_display_state s ON s.workspace_id=c.workspace_id AND s.device_id=c.device_id AND s.display_revision=c.display_revision AND s.group_id IS c.group_id WHERE c.workspace_id=? AND c.device_id=? AND c.command_id=? AND c.request_hash=? AND ${auth} AND (c.group_id IS NULL OR EXISTS(SELECT 1 FROM live_activity_groups g WHERE g.group_id=c.group_id AND g.registration_revision=c.registration_revision AND ${active}))`).bind(ws, dev, b.commandId, hash, ...authArgs).first();
        return accepted ? json(receipt(accepted)) : problem(409, 'activity_revision_conflict');
    };
    if (replay)
        return currentReceipt();
    let encrypted = null;
    if (group) {
        const end = Date.parse(b.endsAt), coverage = Date.parse(b.coverageExpiresAt), now = Date.now();
        if (!Number.isFinite(end) || new Date(end).toISOString() !== b.endsAt || !Number.isFinite(coverage) || new Date(coverage).toISOString() !== b.coverageExpiresAt || end <= now || end > now + 8 * 3600000 || coverage <= now || coverage > Math.min(end, now + 4 * 3600000))
            return problem(400, 'invalid_ends_at');
        encrypted = await encryptStored(env, { token: b.activityToken });
        if (!encrypted)
            return problem(503, 'delivery_secret_unavailable');
    }
    const op = crypto.randomUUID(), renew = group && b.expectedRegistrationRevision > 0;
    const existsOp = 'EXISTS(SELECT 1 FROM live_activity_commands WHERE operation_id=?)';
    let condition = `s.display_revision=? AND ${auth}`;
    let args = [b.expectedDisplayRevision, ...authArgs];
    if (group) {
        condition += ` AND EXISTS(SELECT 1 FROM workspaces WHERE workspace_id=s.workspace_id AND writer_device_id=? AND source_epoch=? AND EXISTS(SELECT 1 FROM devices writer WHERE writer.device_id=workspaces.writer_device_id AND writer.workspace_id=workspaces.workspace_id AND writer.role='writer' AND writer.revoked_at IS NULL))`;
        args.push(b.sourceDeviceId, b.sourceEpoch);
        if (renew) {
            condition += ` AND s.group_id=? AND s.stopped=0 AND EXISTS(SELECT 1 FROM live_activity_groups g WHERE g.group_id=s.group_id AND g.retired=0 AND g.disabled=0 AND g.projection_consent=1 AND g.registration_revision=? AND g.source_device_id=? AND g.source_epoch=? AND g.window_ids=? AND g.ends_at=? AND g.ends_at>?)`;
            args.push(group, b.expectedRegistrationRevision, b.sourceDeviceId, b.sourceEpoch, JSON.stringify(b.windowIds), b.endsAt, iso());
        }
        else {
            condition += ' AND NOT EXISTS(SELECT 1 FROM live_activity_groups WHERE group_id=?)';
            args.push(group);
        }
    }
    const revision = b.expectedDisplayRevision + (renew ? 0 : 1), reg = group ? b.expectedRegistrationRevision + 1 : null;
    const batch = [env.DB.prepare(`INSERT OR IGNORE INTO live_activity_commands(workspace_id,device_id,command_id,request_hash,operation_id,display_revision,registration_revision,group_id) SELECT ?,?,?,?,?,?,?,? FROM live_activity_display_state s WHERE s.workspace_id=? AND s.device_id=? AND ${condition}`).bind(ws, dev, b.commandId, hash, op, revision, reg, group, ws, dev, ...args)];
    if (!renew) {
        batch.push(env.DB.prepare(`UPDATE live_activity_groups SET retired=1,lease_id=NULL WHERE workspace_id=? AND device_id=? AND retired=0 AND ${existsOp}`).bind(ws, dev, op));
        batch.push(env.DB.prepare(`UPDATE live_activity_display_state SET display_revision=?,group_id=?,stopped=? WHERE workspace_id=? AND device_id=? AND ${existsOp}`).bind(revision, group, group ? 0 : 1, ws, dev, op));
    }
    if (group && renew)
        batch.push(env.DB.prepare(`UPDATE live_activity_groups SET token_ciphertext=?,environment=?,coverage_expires_at=?,registration_revision=?,bundle_revision=bundle_revision+1,pending_revision=bundle_revision+1,lease_id=NULL,backoff_until=NULL WHERE group_id=? AND ${existsOp}`).bind(encrypted, b.environment, b.coverageExpiresAt, reg, group, op));
    if (group && !renew) {
        batch.push(env.DB.prepare(`INSERT INTO live_activity_groups(group_id,workspace_id,device_id,source_device_id,source_epoch,window_ids,token_ciphertext,environment,ends_at,coverage_expires_at,registration_revision,display_revision) SELECT ?,?,?,?,?,?,?,?,?,?,?,? WHERE ${existsOp}`).bind(group, ws, dev, b.sourceDeviceId, b.sourceEpoch, JSON.stringify(b.windowIds), encrypted, b.environment, b.endsAt, b.coverageExpiresAt, reg, revision, op));
        b.windowIds.forEach((window, slot) => batch.push(env.DB.prepare(`INSERT INTO live_activity_group_windows(group_id,slot,window_id) SELECT ?,?,? WHERE ${existsOp}`).bind(group, slot, window, op)));
    }
    const results = await env.DB.batch(batch);
    return results[0].meta.changes === 1 ? json(receipt({ display_revision: revision, registration_revision: reg, group_id: group })) : currentReceipt();
}
// SQL constructs the ordered full snapshot in the claim transaction, never by N independent reads.
const snapshot = `(SELECT json_group_array(json(row)) FROM (SELECT json_object('windowID',m.window_id,'remainingBps',json_extract(p.projection_json,'$.remainingBps'),'displayState',COALESCE(json_extract(p.projection_json,'$.displayState'),'unavailable'),'observedAt',CAST(strftime('%s',json_extract(p.projection_json,'$.observedAt')) AS INTEGER),'staleAt',CAST(strftime('%s',json_extract(p.projection_json,'$.staleAt')) AS INTEGER),'resetsAt',CAST(strftime('%s',json_extract(p.projection_json,'$.resetsAt')) AS INTEGER),'sequence',COALESCE(p.sequence,0)) AS row FROM live_activity_group_windows m LEFT JOIN live_projections p ON p.workspace_id=g.workspace_id AND p.source_epoch=g.source_epoch AND p.window_id=m.window_id WHERE m.group_id=g.group_id ORDER BY m.slot))`;
export function buildV2Payload(group) {
    const rows = JSON.parse(group.claimed_json), timestamp = group.last_event_timestamp;
    const stale = Math.min(Math.floor(Date.parse(group.ends_at) / 1000), ...rows.map(r => r.observedAt === null || r.staleAt === null || r.displayState === 'unavailable' ? timestamp : r.staleAt));
    return { aps: { timestamp, event: 'update', 'content-state': { version: 2, bundleRevision: group.claimed_revision, rows }, 'stale-date': stale } };
}
export async function flushV2(env, transport, decryptToken) {
    if (!await v2Available(env))
        return;
    const now = iso(), second = Math.floor(Date.now() / 1000), cooldown = new Date(Date.now() - 300000).toISOString();
    const eligible = `${active} AND g.pending_revision IS NOT NULL AND g.ends_at>? AND g.coverage_expires_at>? AND (g.lease_until IS NULL OR g.lease_until<=? OR g.lease_id IS NULL) AND (g.backoff_until IS NULL OR g.backoff_until<=?) AND (g.last_sent_at IS NULL OR g.last_sent_at<=?) AND g.last_event_timestamp<?`;
    const params = [now, now, now, now, cooldown, second];
    const candidates = await env.DB.prepare(`SELECT g.group_id FROM live_activity_groups g WHERE ${eligible} ORDER BY g.last_sent_at LIMIT 32`).bind(...params).all();
    for (const c of candidates.results) {
        const lease = crypto.randomUUID();
        const claimed = await env.DB.prepare(`UPDATE live_activity_groups AS g SET lease_id=?,lease_until=?,claimed_revision=pending_revision,claimed_json=${snapshot},last_event_timestamp=? WHERE group_id=? AND ${eligible}`).bind(lease, new Date(Date.now() + 60000).toISOString(), second, c.group_id, ...params).run();
        if (claimed.meta.changes !== 1)
            continue;
        const g = await env.DB.prepare('SELECT * FROM live_activity_groups WHERE group_id=? AND lease_id=?').bind(c.group_id, lease).first();
        if (!g)
            continue;
        const fence = `g.group_id=? AND g.lease_id=? AND g.display_revision=? AND g.registration_revision=? AND g.source_device_id=? AND g.source_epoch=? AND g.claimed_revision=? AND g.lease_until>? AND g.ends_at>? AND g.coverage_expires_at>? AND ${active}`;
        const identity = () => [g.group_id, lease, g.display_revision, g.registration_revision, g.source_device_id, g.source_epoch, g.claimed_revision, iso(), iso(), iso()];
        let result = { kind: 'failed' };
        try {
            const token = await decryptToken(env, g.token_ciphertext);
            if (!token)
                result = { kind: 'disabled' };
            else {
                if (!await env.DB.prepare(`SELECT 1 FROM live_activity_groups g WHERE ${fence}`).bind(...identity()).first())
                    continue;
                // A stop after this final check cannot recall an already accepted APNs request.
                result = await dispatchPush(transport, token, g.environment, buildV2Payload(g));
            }
        }
        catch {
            result = { kind: 'failed' };
        }
        const mutation = result.kind === 'sent' ? `last_sent_at=?,pending_revision=CASE WHEN pending_revision=claimed_revision THEN NULL ELSE pending_revision END` : result.kind === 'disabled' ? `disabled=1,pending_revision=NULL` : `backoff_until=?`;
        const values = result.kind === 'sent' ? [iso()] : result.kind === 'disabled' ? [] : [new Date(Date.now() + 60000).toISOString()];
        await env.DB.prepare(`UPDATE live_activity_groups AS g SET ${mutation},lease_id=NULL,lease_until=NULL WHERE ${fence}`).bind(...values, ...identity()).run();
    }
}
