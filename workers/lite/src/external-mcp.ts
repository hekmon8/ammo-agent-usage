import { type Env, type Device, json, problem, readJson, sha256, bearer, isRecord, hasOnly, stringField } from "./worker.js";

const timestamp = (v: unknown): v is string => typeof v === "string" && Number.isFinite(Date.parse(v));
const id = /^[A-Za-z0-9_-]{1,80}$/;
const keys = ["id", "providerId", "unit", "currency", "quotaKey", "availability", "remainingBps", "amount", "limit", "quality", "fetchOutcome", "observedAt", "staleAt", "resetsAt"];
function canonicalSnapshot(value: Record<string, unknown>): string {
  const windows = value.windows as Record<string, unknown>[];
  return JSON.stringify({ sequence: value.sequence, capturedAt: value.capturedAt, sourceEpoch: value.sourceEpoch,
    windows: windows.map(window => Object.fromEntries(keys.map(key => [key, window[key]]))) });
}
export function validMCPWindow(v: unknown): boolean {
  if (!isRecord(v) || !hasOnly(v, keys) || Object.keys(v).length !== keys.length) return false;
  return stringField(v.id, 80, id) && stringField(v.providerId, 80, id)
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
  if (new URL(request.url).pathname === "/v1/mcp-access") {
    if (request.method === "DELETE") {
      await env.DB.prepare(`DELETE FROM mcp_access WHERE workspace_id = ? AND ${activeWriter}`).bind(writer.workspace_id, ...credentials).run();
      return json({ accepted: true });
    }
    if (request.method !== "PUT") return problem(405, "method_not_allowed");
    const body = await readJson(request);
    if (!body || body === "too_large" || !hasOnly(body, ["tokenHash", "consent", "sourceEpoch"]) || body.sourceEpoch !== source.source_epoch || body.consent !== "share_redacted_quotas" || !stringField(body.tokenHash, 64, /^[a-f0-9]{64}$/)) return problem(400, "invalid_request");
    const expiry = new Date(Date.now() + 90 * 86400000).toISOString();
    const result = await env.DB.prepare(`INSERT INTO mcp_access(workspace_id, token_hash, source_epoch, expires_at) SELECT ?, ?, ?, ? WHERE ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?) ON CONFLICT(workspace_id) DO UPDATE SET token_hash=excluded.token_hash, source_epoch=excluded.source_epoch, expires_at=excluded.expires_at, source_sequence=0, snapshot_json=NULL, captured_at=NULL`).bind(writer.workspace_id, body.tokenHash, source.source_epoch, expiry, ...credentials, writer.workspace_id, source.source_epoch).run();
    return result.meta.changes === 1 ? json({ accepted: true, expiresAt: expiry }) : problem(409, "not_admitted");
  }
  if (request.method !== "PUT") return problem(405, "method_not_allowed");
  const body = await readJson(request, 192 * 1024);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["sequence", "capturedAt", "windows", "sourceEpoch"]) || body.sourceEpoch !== source.source_epoch || !Number.isSafeInteger(body.sequence) || Number(body.sequence) < 1 || !timestamp(body.capturedAt) || Date.parse(body.capturedAt) > Date.now() + 120000 || !Array.isArray(body.windows) || body.windows.length > 80 || !body.windows.every(validMCPWindow) || new Set(body.windows.map(v => v.id)).size !== body.windows.length) return problem(400, "invalid_projection");
  const canonical = canonicalSnapshot(body);
  const existing = await env.DB.prepare(`SELECT source_sequence, snapshot_json FROM mcp_access WHERE workspace_id = ? AND source_epoch = ? AND expires_at > ? AND ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?)`)
    .bind(writer.workspace_id, source.source_epoch, new Date().toISOString(), ...credentials, writer.workspace_id, source.source_epoch).first<{ source_sequence: number; snapshot_json: string | null }>();
  if (existing && existing.source_sequence === body.sequence && existing.snapshot_json) {
    try {
      const previous: unknown = JSON.parse(existing.snapshot_json);
      if (isRecord(previous) && canonicalSnapshot(previous) === canonical) return json({ accepted: true });
    } catch { /* Invalid stored data is never accepted as an idempotent retry. */ }
    return problem(409, "mcp_disabled_or_sequence_conflict");
  }
  const result = await env.DB.prepare(`UPDATE mcp_access SET snapshot_json = ?, source_sequence = ?, captured_at = ? WHERE workspace_id = ? AND source_epoch = ? AND source_sequence < ? AND expires_at > ? AND ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?)`).bind(canonical, body.sequence, body.capturedAt, writer.workspace_id, source.source_epoch, body.sequence, new Date().toISOString(), ...credentials, writer.workspace_id, source.source_epoch).run();
  if (result.meta.changes === 1) return json({ accepted: true });
  // The first read can race with an identical PUT. Recheck under the same
  // writer, epoch, and expiry conditions before reporting a conflict.
  const concurrent = await env.DB.prepare(`SELECT source_sequence, snapshot_json FROM mcp_access WHERE workspace_id = ? AND source_epoch = ? AND expires_at > ? AND ${activeWriter} AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?)`)
    .bind(writer.workspace_id, source.source_epoch, new Date().toISOString(), ...credentials, writer.workspace_id, source.source_epoch).first<{ source_sequence: number; snapshot_json: string | null }>();
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
  const access = await env.DB.prepare("SELECT snapshot_json FROM mcp_access WHERE token_hash = ? AND expires_at > ? AND EXISTS (SELECT 1 FROM workspaces w JOIN devices d ON d.device_id = w.writer_device_id WHERE w.workspace_id = mcp_access.workspace_id AND w.source_epoch = mcp_access.source_epoch AND d.revoked_at IS NULL)").bind(await sha256(token), new Date().toISOString()).first<{ snapshot_json: string | null }>();
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
    return result({ protocolVersion: ["2025-03-26", "2025-06-18", "2025-11-25"].includes(requested) ? requested : "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "quota-island-http", version: "1.0.0" }, instructions: "Read-only redacted quotas. No account names or history. Respect stale and unavailable states; never total percentages across providers." });
  }
  if (body.method === "ping") return result({});
  const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
  if (body.method === "tools/list") return result({ tools: [
    { name: "quota_list", description: "Latest shared quota windows; inspect stale/unavailable states.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations },
    { name: "quota_get", description: "Read one shared quota window.", inputSchema: { type: "object", properties: { windowId: { type: "string" } }, required: ["windowId"], additionalProperties: false }, annotations },
    { name: "quota_health", description: "Whether a shared observation is available.", inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations }
  ] });
  if (body.method !== "tools/call") return rpcError(-32601, "Method not found");
  if (!isRecord(body.params) || !["quota_list", "quota_get", "quota_health"].includes(body.params.name as string)) return rpcError(-32602, "Unknown tool");
  const args = body.params.arguments ?? {};
  if (!isRecord(args) || !hasOnly(args, body.params.name === "quota_get" ? ["windowId"] : []) || body.params.name === "quota_get" && !stringField(args.windowId, 80, id)) return rpcError(-32602, "Invalid arguments");
  const data = access.snapshot_json ? JSON.parse(access.snapshot_json) : null;
  const content = (value: unknown, isError = false) => result({ content: [{ type: "text", text: JSON.stringify(value) }], isError });
  if (!data) return content({ available: false, reason: "No shared observation; enable sharing and refresh on Mac." }, body.params.name !== "quota_health");
  const windows = data.windows.map((w: Record<string, unknown>) => ({ ...w, stale: !w.staleAt || Date.parse(w.staleAt as string) <= Date.now() || !w.observedAt || Date.parse(w.observedAt as string) > Date.now() + 120000 }));
  if (body.params.name === "quota_health") return content({ available: true, capturedAt: data.capturedAt, windowCount: windows.length, stale: windows.length === 0 || windows.every((w: { stale: boolean }) => w.stale) });
  if (body.params.name === "quota_get") { const window = windows.find((w: { id: string }) => w.id === args.windowId); return content(window ?? { available: false, reason: "Window not found" }, !window); }
  return content({ capturedAt: data.capturedAt, windows });
}
