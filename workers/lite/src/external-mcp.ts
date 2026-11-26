import { type Env, type Device, json, problem, readJson, sha256, bearer, isRecord, hasOnly, stringField } from "./worker.js";

const timestamp = (v: unknown): v is string => typeof v === "string" && Number.isFinite(Date.parse(v));
const id = /^[A-Za-z0-9_-]{1,80}$/;
const windowId = /^(?:[A-Za-z0-9_-]{1,80}|rs\.[a-f0-9]{64})$/;
const hash = /^[a-f0-9]{64}$/;
const maxReceivedShares = 32;
const unexpired = "(never_expires = 1 OR expires_at > ?)";
const activeGrant = `token_hash = ? AND ${unexpired} AND EXISTS (SELECT 1 FROM workspaces w JOIN devices d ON d.device_id = w.writer_device_id WHERE w.workspace_id = mcp_access.workspace_id AND w.source_epoch = mcp_access.source_epoch AND d.revoked_at IS NULL)`;
type ShareRef = { shareId: string; viewerTokenHash: string };
type QuotaWindow = Record<string, unknown> & { id: string };
type Observation = { capturedAt: string; windows: QuotaWindow[] };

function validShareRef(value: unknown): value is ShareRef {
  return isRecord(value) && hasOnly(value, ["shareId", "viewerTokenHash"]) && stringField(value.shareId, 80, id) && stringField(value.viewerTokenHash, 64, hash);
}
const keys = ["id", "providerId", "account", "unit", "currency", "quotaKey", "availability", "remainingBps", "amount", "limit", "quality", "fetchOutcome", "observedAt", "staleAt", "resetsAt"];
// `account` is an optional opaque tag so projections from clients that predate it stay valid.
const requiredKeys = keys.filter(key => key !== "account");
function canonicalSnapshot(value: Record<string, unknown>): string {
  const windows = value.windows as Record<string, unknown>[];
  return JSON.stringify({ sequence: value.sequence, capturedAt: value.capturedAt, sourceEpoch: value.sourceEpoch,
    windows: windows.map(window => Object.fromEntries(keys.map(key => [key, window[key]]))) });
}
export function validMCPWindow(v: unknown): boolean {
  if (!isRecord(v) || !hasOnly(v, keys) || !requiredKeys.every(key => key in v)) return false;
  return stringField(v.id, 80, id) && stringField(v.providerId, 80, id)
    && (v.account === undefined || v.account === null || stringField(v.account, 64, hash))
    && stringField(v.quotaKey, 80, /^[A-Za-z0-9_.-]+$/)
    && (v.currency === null || typeof v.currency === "string" && /^[A-Z]{3}$/.test(v.currency))
    && ["percent", "tokens", "requests", "credits", "money"].includes(v.unit as string)
    && ["available", "unavailable", "unlimited"].includes(v.availability as string)
    && ["reported", "estimated", "unknown"].includes(v.quality as string)
    && ["ok", "error", "throttled", "disabled", "auth_required"].includes(v.fetchOutcome as string)
    && (v.remainingBps === null || Number.isInteger(v.remainingBps) && Number(v.remainingBps) >= 0 && Number(v.remainingBps) <= 10000)
    && [v.amount, v.limit].every(x => x === null || typeof x === "string" && x.length <= 48 && /^(0|[1-9][0-9]*)(\.[0-9]{1,12})?$/.test(x))
    && [v.observedAt, v.staleAt, v.resetsAt].every(x => x === null || timestamp(x))
    && (v.observedAt === null || Date.parse(v.observedAt as string) <= Date.now() + 120000)
    && (v.staleAt === null || v.observedAt === null || Date.parse(v.staleAt as string) >= Date.parse(v.observedAt as string));
}

export async function manageMCP(request: Request, env: Env, writer: Device): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const source = await env.DB.prepare("SELECT source_epoch FROM workspaces WHERE workspace_id = ? AND writer_device_id = ?").bind(writer.workspace_id, writer.device_id).first<{ source_epoch: string }>();
  if (!source) return problem(403, "role_forbidden");
  const activeWriter = "EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'writer' AND revoked_at IS NULL)";
  const credentials = [writer.device_id, writer.workspace_id, writer.token_hash];
  const pathname = new URL(request.url).pathname;
  const currentGrant = `workspace_id = ? AND source_epoch = ? AND ${unexpired} AND ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ? AND writer_device_id = ?)`;
  const grantBindings = () => [writer.workspace_id, source.source_epoch, new Date().toISOString(), ...credentials, writer.workspace_id, source.source_epoch, writer.device_id];
  if (pathname === "/v1/mcp-access") {
    if (request.method === "DELETE") {
      await env.DB.prepare(`DELETE FROM mcp_access WHERE workspace_id = ? AND ${activeWriter}`).bind(writer.workspace_id, ...credentials).run();
      return json({ accepted: true });
    }
    const body = await readJson(request);
    if (request.method === "PATCH") {
      if (!body || body === "too_large" || !hasOnly(body, ["lifetime", "tokenHash"]) || body.lifetime !== "until_revoked" || !stringField(body.tokenHash, 64, hash)) return problem(400, "invalid_request");
      const updated = await env.DB.prepare(`UPDATE mcp_access SET never_expires = 1 WHERE ${currentGrant} AND token_hash = ?`).bind(...grantBindings(), body.tokenHash).run();
      return updated.meta.changes === 1 ? json({ accepted: true, expiresAt: null }) : problem(409, "not_admitted");
    }
    if (request.method !== "PUT") return problem(405, "method_not_allowed");
    if (!body || body === "too_large" || !hasOnly(body, ["tokenHash", "consent", "sourceEpoch"]) || body.sourceEpoch !== source.source_epoch || body.consent !== "share_redacted_quotas" || !stringField(body.tokenHash, 64, hash)) return problem(400, "invalid_request");
    const expiry = new Date(Date.now() + 90 * 86400000).toISOString();
    const result = await env.DB.prepare(`INSERT INTO mcp_access(workspace_id, token_hash, source_epoch, expires_at) SELECT ?, ?, ?, ? WHERE ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?) ON CONFLICT(workspace_id) DO UPDATE SET token_hash=excluded.token_hash, source_epoch=excluded.source_epoch, expires_at=excluded.expires_at, source_sequence=0, snapshot_json=NULL, captured_at=NULL, never_expires=0, received_shares_json=NULL`).bind(writer.workspace_id, body.tokenHash, source.source_epoch, expiry, ...credentials, writer.workspace_id, source.source_epoch).run();
    return result.meta.changes === 1 ? json({ accepted: true, expiresAt: expiry }) : problem(409, "not_admitted");
  }
  if (request.method !== "PUT") return problem(405, "method_not_allowed");
  if (pathname === "/v1/mcp-shares") {
    const body = await readJson(request);
    if (!body || body === "too_large" || !hasOnly(body, ["shares", "tokenHash"]) || !stringField(body.tokenHash, 64, hash) || !Array.isArray(body.shares) || body.shares.length > maxReceivedShares || !body.shares.every(validShareRef) || new Set(body.shares.map(ref => ref.shareId)).size !== body.shares.length) return problem(400, "invalid_request");
    const refs = body.shares.map(({ shareId, viewerTokenHash }) => ({ shareId, viewerTokenHash }));
    const updated = await env.DB.prepare(`UPDATE mcp_access SET received_shares_json = ? WHERE ${currentGrant} AND token_hash = ?`).bind(refs.length ? JSON.stringify(refs) : null, ...grantBindings(), body.tokenHash).run();
    return updated.meta.changes === 1 ? json({ accepted: true }) : problem(409, "not_admitted");
  }
  const body = await readJson(request, 192 * 1024);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["sequence", "capturedAt", "windows", "sourceEpoch"]) || body.sourceEpoch !== source.source_epoch || !Number.isSafeInteger(body.sequence) || Number(body.sequence) < 1 || !timestamp(body.capturedAt) || Date.parse(body.capturedAt) > Date.now() + 120000 || !Array.isArray(body.windows) || body.windows.length > 80 || !body.windows.every(validMCPWindow) || new Set(body.windows.map(v => v.id)).size !== body.windows.length) return problem(400, "invalid_projection");
  const canonical = canonicalSnapshot(body);
  const existing = await env.DB.prepare(`SELECT source_sequence, snapshot_json FROM mcp_access WHERE ${currentGrant}`)
    .bind(...grantBindings()).first<{ source_sequence: number; snapshot_json: string | null }>();
  if (existing && existing.source_sequence === body.sequence && existing.snapshot_json) {
    try {
      const previous: unknown = JSON.parse(existing.snapshot_json);
      if (isRecord(previous) && canonicalSnapshot(previous) === canonical) return json({ accepted: true });
    } catch { /* Invalid stored data is never accepted as an idempotent retry. */ }
    return problem(409, "mcp_disabled_or_sequence_conflict");
  }
  const result = await env.DB.prepare(`UPDATE mcp_access SET snapshot_json = ?, source_sequence = ?, captured_at = ? WHERE source_sequence < ? AND ${currentGrant}`).bind(canonical, body.sequence, body.capturedAt, body.sequence, ...grantBindings()).run();
  if (result.meta.changes === 1) return json({ accepted: true });
  // The first read can race with an identical PUT. Recheck under the same
  // writer, epoch, and expiry conditions before reporting a conflict.
  const concurrent = await env.DB.prepare(`SELECT source_sequence, snapshot_json FROM mcp_access WHERE ${currentGrant}`)
    .bind(...grantBindings()).first<{ source_sequence: number; snapshot_json: string | null }>();
  if (concurrent && concurrent.source_sequence === body.sequence && concurrent.snapshot_json) {
    try {
      const previous: unknown = JSON.parse(concurrent.snapshot_json);
      if (isRecord(previous) && canonicalSnapshot(previous) === canonical) return json({ accepted: true });
    } catch { /* Invalid stored data is never accepted as an idempotent retry. */ }
  }
  return problem(409, "mcp_disabled_or_sequence_conflict");
}

export async function handleMCP(request: Request, env: Env): Promise<Response> {
  // No browser origins are authorized; clients use an explicit bearer over HTTPS.
  if (request.headers.has("origin")) return problem(403, "origin_forbidden");
  const token = bearer(request);
  if (!token) return problem(401, "invalid_credential");
  const tokenHash = await sha256(token);
  const access = await env.DB.prepare(`SELECT 1 FROM mcp_access WHERE ${activeGrant}`).bind(tokenHash, new Date().toISOString()).first();
  if (!access) return problem(401, "invalid_credential");
  if (request.method !== "POST") return problem(405, "method_not_allowed");
  if (!request.headers.get("content-type")?.startsWith("application/json")) return problem(415, "unsupported_media_type");
  const accept = request.headers.get("accept") ?? "";
  if (!accept.includes("application/json") || !accept.includes("text/event-stream")) return problem(406, "unsupported_accept");
  const version = request.headers.get("mcp-protocol-version");
  if (version && !["2025-03-26", "2025-06-18", "2025-11-25"].includes(version)) return problem(400, "unsupported_protocol_version");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  const rpcError = (code: number, message: string) => json({ jsonrpc: "2.0", id: body ? body.id ?? null : null, error: { code, message } });
  if (!body || body.jsonrpc !== "2.0" || typeof body.method !== "string" || (body.id !== undefined && typeof body.id !== "string" && typeof body.id !== "number")) return rpcError(-32600, "Invalid Request");
  if (body.id === undefined) return new Response(null, { status: 202, headers: { "cache-control": "no-store" } });
  const result = (value: unknown) => json({ jsonrpc: "2.0", id: body.id, result: value });
  if (body.method === "initialize") {
    if (!isRecord(body.params) || typeof body.params.protocolVersion !== "string" || !isRecord(body.params.capabilities) || !isRecord(body.params.clientInfo) || !stringField(body.params.clientInfo.name, 128) || !stringField(body.params.clientInfo.version, 64)) return rpcError(-32602, "Invalid initialize params");
    const requested = body.params.protocolVersion;
    return result({ protocolVersion: ["2025-03-26", "2025-06-18", "2025-11-25"].includes(requested) ? requested : "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "quota-island-http", version: "1.0.0" }, instructions: "Read-only redacted quotas. No account names or history. Several accounts of one provider share providerId; group their windows by the opaque account tag. Respect stale and unavailable states; never total percentages across providers." });
  }
  if (body.method === "ping") return result({});
  const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
  if (body.method === "tools/list") return result({ tools: [
    { name: "quota_list", description: "Latest shared quota windows; several accounts of one provider are grouped by the opaque account tag. Inspect stale/unavailable states.", inputSchema: { type: "object", properties: { account: { type: "string", pattern: "^[a-f0-9]{64}$" } }, additionalProperties: false }, annotations },
    { name: "quota_get", description: "Read one shared quota window.", inputSchema: { type: "object", properties: { windowId: { type: "string" } }, required: ["windowId"], additionalProperties: false }, annotations },
    { name: "quota_health", description: "Whether a shared observation is available.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations }
  ] });
  if (body.method !== "tools/call") return rpcError(-32601, "Method not found");
  if (!isRecord(body.params) || !["quota_list", "quota_get", "quota_health"].includes(body.params.name as string)) return rpcError(-32602, "Unknown tool");
  const args = body.params.arguments ?? {};
  if (!isRecord(args) || !hasOnly(args, body.params.name === "quota_get" ? ["windowId"] : body.params.name === "quota_list" ? ["account"] : [])
    || body.params.name === "quota_get" && !stringField(args.windowId, 80, windowId)
    || body.params.name === "quota_list" && args.account !== undefined && !stringField(args.account, 64, hash)) return rpcError(-32602, "Invalid arguments");
  // Recheck after reading the request body. Ingress bounds the join to 80 local + 32 × 80 received windows.
  const { results: rows } = await env.DB.prepare(`WITH grant AS (
      SELECT snapshot_json, received_shares_json FROM mcp_access WHERE ${activeGrant}
    )
    SELECT snapshot_json AS projection, NULL AS share_id, NULL AS provider_id, NULL AS captured_at FROM grant
    UNION ALL
    SELECT s.windows_json, s.share_id, s.provider_id, s.captured_at
    FROM grant, json_each(grant.received_shares_json) AS ref
    JOIN quota_shares s ON s.share_id = json_extract(ref.value, '$.shareId')
      AND s.viewer_token_hash = json_extract(ref.value, '$.viewerTokenHash')
    WHERE s.state = 'approved' AND s.windows_json IS NOT NULL AND s.captured_at IS NOT NULL
    ORDER BY share_id`).bind(tokenHash, new Date().toISOString()).all<{ projection: string | null; share_id: string | null; provider_id: string | null; captured_at: string | null }>();
  if (!rows.length) return problem(401, "invalid_credential");
  const local: Observation | null = rows[0].projection ? JSON.parse(rows[0].projection) : null;
  const received = rows.slice(1);
  const content = (value: unknown, isError = false) => result({ content: [{ type: "text", text: JSON.stringify(value) }], isError });
  if (!local && !received.length) return content({ available: false, reason: "No shared observation; enable sharing and refresh on Mac." }, body.params.name !== "quota_health");
  let capturedAt = local?.capturedAt ?? received[0].captured_at!;
  const merged: (QuotaWindow & { source: "local" | "received" })[] = (local?.windows ?? []).map(w => ({ ...w, account: w.account ?? null, source: "local" }));
  for (const row of received) {
    if (Date.parse(row.captured_at!) > Date.parse(capturedAt)) capturedAt = row.captured_at!;
    const occurrences = new Map<unknown, number>();
    const shareWindows: Record<string, unknown>[] = JSON.parse(row.projection!);
    // One share is one account, so its windows share one opaque tag.
    const account = await sha256(JSON.stringify(["share", row.share_id]));
    merged.push(...await Promise.all(shareWindows.map(async w => {
      const n = occurrences.get(w.quotaKey) ?? 0;
      occurrences.set(w.quotaKey, n + 1);
      const id = `rs.${await sha256(JSON.stringify([row.share_id, w.quotaKey, n]))}`;
      return { ...w, id, account, providerId: row.provider_id, source: "received" as const };
    })));
  }
  const now = Date.now();
  let allTimeStale = true;
  const windows: (QuotaWindow & { stale: boolean; source: "local" | "received" })[] = merged.map(w => {
    const observed = Date.parse(w.observedAt as string);
    const reset = Date.parse(w.resetsAt as string);
    const timeStale = !w.staleAt || Date.parse(w.staleAt as string) <= now || !w.observedAt || observed > now + 120000;
    allTimeStale &&= timeStale;
    return { ...w, stale: timeStale || w.fetchOutcome !== "ok" || w.availability === "unavailable"
      || (reset <= now && observed < reset) };
  });
  if (body.params.name === "quota_health") {
    // Existing clients use `stale` for timestamp health, not quota eligibility.
    return content({ available: true, capturedAt, windowCount: windows.length, stale: allTimeStale,
      freshWindowCount: windows.filter(w => !w.stale).length });
  }
  if (body.params.name === "quota_get") { const window = windows.find(w => w.id === args.windowId); return content(window ?? { available: false, reason: "Window not found" }, !window); }
  return content({ capturedAt, windows: args.account === undefined ? windows : windows.filter(w => w.account === args.account) });
}
