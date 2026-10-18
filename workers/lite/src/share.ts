import { bearer, hasOnly, isRecord, json, problem, readJson, sha256, stringField, type Device, type Env } from "./worker.js";

const id = /^[A-Za-z0-9_-]{1,80}$/;
const hash = /^[a-f0-9]{64}$/;
const decimal = /^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,12})?$/;
const timestamp = (value: unknown): value is string => typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value)) && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:\d\d)$/.test(value);
const optionalTimestamp = (value: unknown): value is string | null => value === null || timestamp(value);
const activeWriter = "EXISTS (SELECT 1 FROM devices AS d JOIN workspaces AS w ON w.workspace_id = d.workspace_id AND w.writer_device_id = d.device_id WHERE d.device_id = ? AND d.workspace_id = quota_shares.workspace_id AND d.token_hash = ? AND d.role = 'writer' AND d.revoked_at IS NULL)";
const lifetime = 10 * 60_000;
const deliveryLifetime = 24 * 60 * 60_000;
const claimLifetime = 24 * 60 * 60_000;
const maxProjectionBytes = 96 * 1024;
type Share = { share_id: string; connection_id: string; provider_id: string; account_id: string; label: string; state: string; recipient_name: string | null; claim_id: string | null; verification_code: string | null; expires_at: string };
type ClaimResult = { state: string; viewer_token_ciphertext: string | null; viewer_token_hash: string | null; delivery_expires_at: string | null };

function token(bytes = 32): string {
  const random = crypto.getRandomValues(new Uint8Array(bytes));
  let binary = "";
  for (const byte of random) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function shareState(share: Share): string { return share.state === "pending" && share.expires_at <= new Date().toISOString() ? "expired" : share.state; }
function writerFields(share: Share) {
  return { shareId: share.share_id, connectionId: share.connection_id, providerId: share.provider_id, accountId: share.account_id, label: share.label, state: shareState(share), recipientName: share.recipient_name, claimId: share.claim_id, verificationCode: share.verification_code, expiresAt: share.expires_at };
}
function windowValid(value: unknown): boolean {
  if (!isRecord(value) || !hasOnly(value, ["quotaKey", "unit", "currency", "availability", "remainingBps", "amount", "limit", "quality", "fetchOutcome", "observedAt", "staleAt", "resetsAt"]) || Object.keys(value).length !== 12) return false;
  if (!stringField(value.quotaKey, 80, id) || !["percent", "tokens", "requests", "credits", "money"].includes(value.unit as string) || !(value.currency === null || (typeof value.currency === "string" && /^[A-Z]{3}$/.test(value.currency)))) return false;
  if (!["available", "unavailable", "unlimited"].includes(value.availability as string) || !(value.remainingBps === null || (Number.isInteger(value.remainingBps) && (value.remainingBps as number) >= 0 && (value.remainingBps as number) <= 10_000))) return false;
  if (![value.amount, value.limit].every((number) => number === null || (typeof number === "string" && number.length <= 48 && decimal.test(number)))) return false;
  if (!["reported", "estimated", "unknown"].includes(value.quality as string) || !["ok", "error", "throttled", "disabled", "auth_required"].includes(value.fetchOutcome as string)) return false;
  if (![value.observedAt, value.staleAt, value.resetsAt].every(optionalTimestamp)) return false;
  return (value.observedAt === null || value.staleAt === null || Date.parse(value.staleAt as string) >= Date.parse(value.observedAt as string)) && JSON.stringify(value).length <= 1024;
}
function validProjection(value: Record<string, unknown>): value is { capturedAt: string; windows: Record<string, unknown>[] } {
  return hasOnly(value, ["capturedAt", "windows"]) && Object.keys(value).length === 2 && timestamp(value.capturedAt) && Date.parse(value.capturedAt) <= Date.now() + 120_000 && Array.isArray(value.windows) && value.windows.length <= 80 && value.windows.every(windowValid);
}
function base64Bytes(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) return null;
  try { const decoded = atob(value.replace(/-/g, "+").replace(/_/g, "/") + "="); return decoded.length === 32 ? Uint8Array.from(decoded, (c) => c.charCodeAt(0)) : null; } catch { return null; }
}
async function deliveryKey(env: Env): Promise<CryptoKey | null> {
  const bytes = env.DELIVERY_ENCRYPTION_KEY && base64Bytes(env.DELIVERY_ENCRYPTION_KEY);
  return bytes ? crypto.subtle.importKey("raw", bytes.slice().buffer, "AES-GCM", false, ["encrypt", "decrypt"]) : null;
}
async function sealViewerToken(env: Env, value: string): Promise<string | null> {
  const key = await deliveryKey(env); if (!key) return null;
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, new TextEncoder().encode(value)));
  return JSON.stringify({ nonce: tokenBytes(nonce), encrypted: tokenBytes(encrypted) });
}
function tokenBytes(bytes: Uint8Array): string {
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
async function openViewerToken(env: Env, packed: string): Promise<string | null> {
  const key = await deliveryKey(env); if (!key) return null;
  try {
    const value: unknown = JSON.parse(packed);
    if (!isRecord(value) || !stringField(value.nonce, 16, /^[A-Za-z0-9_-]+$/) || !stringField(value.encrypted, 128, /^[A-Za-z0-9_-]+$/)) return null;
    const decode = (text: string) => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - text.length % 4) % 4)), (c) => c.charCodeAt(0));
    const nonce = decode(value.nonce), encrypted = decode(value.encrypted);
    if (nonce.length !== 12 || encrypted.length !== 59) return null;
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, encrypted);
    const output = new TextDecoder().decode(plaintext);
    return /^[A-Za-z0-9_-]{43}$/.test(output) ? output : null;
  } catch { return null; }
}
async function create(request: Request, env: Env, writer: Device): Promise<Response> {
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["connectionId", "providerId", "accountId", "label", "inviteSecretHash"]) || Object.keys(body).length !== 5 || !stringField(body.connectionId, 80, id) || !stringField(body.providerId, 80, id) || !stringField(body.accountId, 256) || !stringField(body.label, 80) || !stringField(body.inviteSecretHash, 64, hash)) return problem(400, "invalid_share");
  const shareId = token(18), expiresAt = new Date(Date.now() + lifetime).toISOString();
  try {
    const stored = await env.DB.prepare(`INSERT INTO quota_shares (share_id,workspace_id,writer_device_id,connection_id,provider_id,account_id,label,invite_secret_hash,state,expires_at,created_at) SELECT ?,w.workspace_id,?,?,?,?,?,?,'pending',?,? FROM workspaces AS w JOIN devices AS d ON d.device_id = w.writer_device_id AND d.workspace_id = w.workspace_id WHERE w.workspace_id = ? AND d.device_id = ? AND d.token_hash = ? AND d.role = 'writer' AND d.revoked_at IS NULL`)
      .bind(shareId, writer.device_id, body.connectionId, body.providerId, body.accountId, body.label, body.inviteSecretHash, expiresAt, new Date().toISOString(), writer.workspace_id, writer.device_id, writer.token_hash).run();
    return (stored.meta.changes ?? 0) === 1 ? json({ shareId, expiresAt }) : problem(401, "invalid_credential");
  } catch { return problem(409, "invite_secret_reused"); }
}
async function list(env: Env, writer: Device): Promise<Response> {
  const rows = await env.DB.prepare(`SELECT share_id,connection_id,provider_id,account_id,label,state,recipient_name,claim_id,verification_code,expires_at FROM quota_shares WHERE workspace_id = ? AND ${activeWriter} ORDER BY created_at DESC`).bind(writer.workspace_id, writer.device_id, writer.token_hash).run<Share>();
  return json(rows.results.map(writerFields));
}
async function claim(request: Request, env: Env, shareId: string): Promise<Response> {
  const secret = bearer(request); if (!secret) return problem(401, "invalid_share_capability");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || Object.keys(body).length !== 1 || !hasOnly(body, ["recipientName"]) || !stringField(body.recipientName, 48)) return problem(400, "invalid_claim");
  const claimId = token(18), claimToken = token();
  const verificationCode = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0");
  const claimedAt = new Date();
  const updated = await env.DB.prepare("UPDATE quota_shares SET state = 'claimed', claim_id = ?, claim_token_hash = ?, recipient_name = ?, verification_code = ?, claimed_at = ? WHERE share_id = ? AND invite_secret_hash = ? AND state = 'pending' AND expires_at > ? AND EXISTS (SELECT 1 FROM devices AS d JOIN workspaces AS w ON w.workspace_id = d.workspace_id AND w.writer_device_id = d.device_id WHERE d.device_id = quota_shares.writer_device_id AND d.workspace_id = quota_shares.workspace_id AND d.role = 'writer' AND d.revoked_at IS NULL)")
    .bind(claimId, await sha256(claimToken), body.recipientName, verificationCode, claimedAt.toISOString(), shareId, await sha256(secret), claimedAt.toISOString()).run();
  if ((updated.meta.changes ?? 0) === 1) return json({ claimId, claimToken, verificationCode });
  // A consumed invite is distinct from an unknown or expired capability only when the supplied secret is valid.
  const existing = await env.DB.prepare("SELECT state, expires_at FROM quota_shares WHERE share_id = ? AND invite_secret_hash = ?").bind(shareId, await sha256(secret)).first<{ state: string; expires_at: string }>();
  return existing && existing.state !== "pending" && existing.state !== "revoked" ? problem(409, "share_already_claimed") : problem(401, "invalid_share_capability");
}
async function result(request: Request, env: Env, shareId: string): Promise<Response> {
  const claimToken = bearer(request); if (!claimToken) return problem(401, "invalid_claim_capability");
  const tokenHash = await sha256(claimToken);
  const row = await env.DB.prepare("SELECT state,viewer_token_ciphertext,viewer_token_hash,delivery_expires_at,claimed_at FROM quota_shares WHERE share_id = ? AND claim_token_hash = ? AND state IN ('claimed','approved')").bind(shareId, tokenHash).first<ClaimResult & { claimed_at: string | null }>();
  if (!row) return problem(401, "invalid_claim_capability");
  if (row.state === "claimed") return row.claimed_at && Date.parse(row.claimed_at) + claimLifetime > Date.now() ? json({ state: "claimed" }) : problem(410, "share_claim_expired");
  if (!row.delivery_expires_at || row.delivery_expires_at <= new Date().toISOString()) return problem(410, "share_delivery_expired");
  if (!row.viewer_token_ciphertext || !row.viewer_token_hash) return problem(500, "share_delivery_unavailable");
  const viewerToken = await openViewerToken(env, row.viewer_token_ciphertext);
  if (!viewerToken || await sha256(viewerToken) !== row.viewer_token_hash) return problem(503, "share_delivery_unavailable");
  const stillActive = await env.DB.prepare("SELECT 1 FROM quota_shares WHERE share_id = ? AND claim_token_hash = ? AND viewer_token_hash = ? AND delivery_expires_at > ? AND state = 'approved'").bind(shareId, tokenHash, row.viewer_token_hash, new Date().toISOString()).first();
  return stillActive ? json({ state: "approved", viewerToken }) : problem(401, "invalid_claim_capability");
}
async function approve(request: Request, env: Env, writer: Device, shareId: string): Promise<Response> {
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || Object.keys(body).length !== 1 || !hasOnly(body, ["claimId"]) || !stringField(body.claimId, 80, id)) return problem(400, "invalid_approval");
  const viewerToken = token(), sealed = await sealViewerToken(env, viewerToken);
  if (!sealed) return problem(503, "delivery_secret_unavailable");
  const approvedAt = new Date();
  const updated = await env.DB.prepare(`UPDATE quota_shares SET state = 'approved', viewer_token_hash = ?, viewer_token_ciphertext = ?, approved_at = ?, delivery_expires_at = ? WHERE share_id = ? AND workspace_id = ? AND claim_id = ? AND state = 'claimed' AND claimed_at > ? AND ${activeWriter}`)
    .bind(await sha256(viewerToken), sealed, approvedAt.toISOString(), new Date(approvedAt.getTime() + deliveryLifetime).toISOString(), shareId, writer.workspace_id, body.claimId, new Date(approvedAt.getTime() - claimLifetime).toISOString(), writer.device_id, writer.token_hash).run();
  return (updated.meta.changes ?? 0) === 1 ? json({ state: "approved" }) : problem(404, "share_not_claimed");
}
async function publish(request: Request, env: Env, writer: Device, shareId: string): Promise<Response> {
  const body = await readJson(request, maxProjectionBytes);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !validProjection(body)) return problem(400, "invalid_share_projection");
  const updated = await env.DB.prepare(`UPDATE quota_shares SET captured_at = ?, windows_json = ? WHERE share_id = ? AND workspace_id = ? AND state = 'approved' AND (captured_at IS NULL OR captured_at <= ?) AND ${activeWriter}`)
    .bind(body.capturedAt, JSON.stringify(body.windows), shareId, writer.workspace_id, body.capturedAt, writer.device_id, writer.token_hash).run();
  return (updated.meta.changes ?? 0) === 1 ? json({ accepted: true }) : problem(409, "share_projection_not_admitted");
}
async function projection(request: Request, env: Env, shareId: string): Promise<Response> {
  const viewerToken = bearer(request); if (!viewerToken) return problem(401, "invalid_viewer_capability");
  const row = await env.DB.prepare("SELECT provider_id,label,captured_at,windows_json FROM quota_shares WHERE share_id = ? AND viewer_token_hash = ? AND state = 'approved'")
    .bind(shareId, await sha256(viewerToken)).first<{ provider_id: string; label: string; captured_at: string | null; windows_json: string | null }>();
  if (!row) return problem(401, "invalid_viewer_capability");
  if (!row.captured_at || !row.windows_json) return problem(404, "share_projection_not_found");
  return json({ shareId, providerId: row.provider_id, label: row.label, capturedAt: row.captured_at, windows: JSON.parse(row.windows_json) });
}
async function revoke(env: Env, writer: Device, shareId: string): Promise<Response> {
  const updated = await env.DB.prepare(`UPDATE quota_shares SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?), invite_secret_hash = ?, claim_token_hash = NULL, viewer_token_hash = NULL, viewer_token_ciphertext = NULL, delivery_expires_at = NULL, captured_at = NULL, windows_json = NULL WHERE share_id = ? AND workspace_id = ? AND ${activeWriter}`)
    .bind(new Date().toISOString(), await sha256(`revoked:${shareId}`), shareId, writer.workspace_id, writer.device_id, writer.token_hash).run();
  return (updated.meta.changes ?? 0) === 1 ? json({ state: "revoked" }) : problem(404, "share_not_found");
}

export function isShareRoute(pathname: string): boolean { return pathname === "/v1/shares" || /^\/v1\/shares\/[A-Za-z0-9_-]{1,80}(?:\/(?:claim|approve|result|projection))?$/.test(pathname); }
export async function handleShare(request: Request, env: Env, authenticate: (request: Request, env: Env) => Promise<Device | null>): Promise<Response> {
  const pathname = new URL(request.url).pathname;
  await env.DB.prepare("UPDATE quota_shares SET viewer_token_ciphertext = NULL WHERE share_id IN (SELECT share_id FROM quota_shares WHERE delivery_expires_at <= ? AND viewer_token_ciphertext IS NOT NULL LIMIT 32)").bind(new Date().toISOString()).run();
  const match = /^\/v1\/shares\/([A-Za-z0-9_-]{1,80})(?:\/(claim|approve|result|projection))?$/.exec(pathname);
  if (match && request.method === "POST" && match[2] === "claim") return claim(request, env, match[1]);
  if (match && request.method === "GET" && match[2] === "result") return result(request, env, match[1]);
  if (match && request.method === "GET" && match[2] === "projection") return projection(request, env, match[1]);
  const writer = await authenticate(request, env);
  if (!writer) return problem(401, "invalid_credential");
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  if (pathname === "/v1/shares" && request.method === "POST") return create(request, env, writer);
  if (pathname === "/v1/shares" && request.method === "GET") return list(env, writer);
  if (match && request.method === "POST" && match[2] === "approve") return approve(request, env, writer, match[1]);
  if (match && request.method === "PUT" && match[2] === "projection") return publish(request, env, writer, match[1]);
  if (match && request.method === "DELETE" && !match[2]) return revoke(env, writer, match[1]);
  return problem(404, "unsupported_route");
}
