import { isV2Route, handleV2, v2Available, flushV2 } from "./single-activity.js";
import { handleMCP, manageMCP } from "./external-mcp.js";
import { buildActivityPayload, dispatchPush } from "./push-dispatch.js";
import { handleShare, isShareRoute } from "./share.js";

export interface D1Result<T = unknown> {
  results: T[];
  meta: { changes?: number };
}

export interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  first<T = unknown>(): Promise<T | null>;
  run<T = unknown>(): Promise<D1Result<T>>;
  all<T = unknown>(): Promise<D1Result<T>>;
}

export interface D1Database {
  prepare(query: string): D1PreparedStatement;
  batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]>;
}

export interface Env {
  DB: D1Database;
  BOOTSTRAP_ENABLED?: string;
  BOOTSTRAP_SECRET?: string;
  BOOTSTRAP_SECRETS?: string;
  DELIVERY_ENCRYPTION_KEY?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
}

type Role = "writer" | "viewer";
export type Device = { device_id: string; workspace_id: string; role: Role; name: string; token_hash: string };
type Pairing = {
  pairing_id: string; workspace_id: string; creator_device_id: string; source_epoch: string; state: string;
  claim_id: string | null; claim_token_hash: string | null; recipient_name: string | null;
  recipient_public_key: string | null; approved_device_id: string | null;
  delivery_ciphertext: string | null; expires_at: string;
};
type Workspace = { workspace_id: string; writer_device_id: string; source_epoch: string; source_public_key: string };
type BootstrapResponse = { workspaceId: string; deviceId: string; deviceToken: string; sourceEpoch: string };
type Envelope = { schemaVersion: "1.0.0"; workspaceId: string; sourceDeviceId: string; sourceEpoch: string; sequence: number; keyId: string; nonce: string; ciphertext: string; tag: string; signature: string; contentHash: string };
type Receipt = { serverRevision: number; sourceSequence: number; receivedAt: string; serverTime: string; contentHash: string };
type Snapshot = { envelope_json: string; source_sequence: number; content_hash: string; server_revision: number; received_at: string; expires_at: string };
type RotationWrap = { deviceId: string; wrappedSnapshotKey: string };
type Rotation = { userConfirmation: "rotate_source_key"; oldSourceEpoch: string; newSourceEpoch: string; newSourcePublicKey: string; keyId: string; wraps: RotationWrap[]; signature: string; trustSignature: string };
type Activity = { activity_id: string; device_id: string; window_id: string; token_ciphertext: string; environment: "sandbox" | "production"; ends_at: string; last_sent_at: string | null; backoff_until: string | null };
type QueuedActivity = Activity & { pending_sequence: number; projection_json: string };
type PushResult = { status: number };
export interface PushTransport { send(token: string, environment: "sandbox" | "production", payload: unknown, style?: "liveactivity" | "alert"): Promise<PushResult | null>; }

const encoder = new TextEncoder();
const idPattern = /^[A-Za-z0-9_-]{1,80}$/;
const keyPattern = /^[A-Za-z0-9_-]+$/;
const hashPattern = /^[a-f0-9]{64}$/;
const bodyLimit = 8 * 1024;
// A sealed 128 KiB snapshot base64-encodes to ~176 KB of envelope JSON.
const snapshotBodyLimit = 256 * 1024;
const pairingLifetimeMs = 10 * 60 * 1000;
const snapshotLifetimeMs = 7 * 24 * 60 * 60 * 1000;
const activityLifetimeMs = 4 * 60 * 60 * 1000;
const activityCooldownMs = 5 * 60 * 1000;
const apnsTokenLifetimeMs = 45 * 60 * 1000;
const apnsTokenLeaseMs = 30 * 1000;

function now(): string { return new Date().toISOString(); }
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function hasOnly(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}
export function stringField(value: unknown, max: number, pattern?: RegExp): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max && (!pattern || pattern.test(value));
}
export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", date: new Date().toUTCString() } });
}
export function problem(status: number, code: string): Response {
  return new Response(JSON.stringify({ type: `https://quota-island.example/problems/${code}`, title: code, status, code }), {
    status, headers: { "content-type": "application/problem+json; charset=utf-8", "cache-control": "no-store", date: new Date().toUTCString() },
  });
}
export async function readJson(request: Request, limit = bodyLimit): Promise<Record<string, unknown> | "too_large" | null> {
  const length = request.headers.get("content-length");
  if (length !== null && /^\d+$/.test(length) && Number(length) > limit) return "too_large";
  if (length !== null && !/^\d+$/.test(length)) return null;
  if (!request.body) return null;
  const reader = request.body.getReader(); const chunks: Uint8Array[] = []; let total = 0;
  while (true) {
    const next = await reader.read();
    if (next.done) break;
    total += next.value.byteLength;
    if (total > limit) { await reader.cancel(); return "too_large"; }
    chunks.push(next.value);
  }
  const bytes = new Uint8Array(total); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes)); return isRecord(parsed) ? parsed : null; } catch { return null; }
}
function randomToken(bytes = 32): string {
  const data = crypto.getRandomValues(new Uint8Array(bytes));
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function randomId(): string { return randomToken(18); }
export async function sha256(value: string): Promise<string> {
  return sha256Bytes(encoder.encode(value));
}
async function sha256Bytes(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", ownedBuffer(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((total, part) => total + part.length, 0); const output = new Uint8Array(length); let offset = 0;
  for (const part of parts) { output.set(part, offset); offset += part.length; }
  return output;
}
export function bearer(request: Request): string | null {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7);
  return token.length >= 32 && token.length <= 256 ? token : null;
}
function base64urlBytes(value: string): Uint8Array | null {
  if (!keyPattern.test(value)) return null;
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  try {
    const binary = atob(padded);
    const decoded = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return encodeBase64url(decoded) === value ? decoded : null;
  } catch { return null; }
}
function ownedBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer as ArrayBuffer;
}
function rawPublicKey(value: unknown): value is string {
  const decoded = typeof value === "string" && value.length <= 128 ? base64urlBytes(value) : null;
  return decoded?.length === 32;
}
function safeConfigEqual(actual: string | undefined, expected: string | undefined): boolean {
  if (!actual || !expected) return false;
  const a = encoder.encode(actual); const b = encoder.encode(expected);
  let difference = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index++) difference |= (a[index % a.length] ?? 0) ^ (b[index % b.length] ?? 0);
  return difference === 0;
}
async function authenticateDevice(request: Request, env: Env): Promise<Device | null> {
  const token = bearer(request); if (!token) return null;
  return env.DB.prepare("SELECT device_id, workspace_id, role, name, token_hash FROM devices WHERE token_hash = ? AND revoked_at IS NULL")
    .bind(await sha256(token)).first<Device>();
}
async function pairingCapability(request: Request, env: Env, pairingId: string, requireClaim: boolean): Promise<Pairing | null> {
  const token = bearer(request); if (!token) return null;
  const column = requireClaim ? "claim_token_hash" : "pairing_secret_hash";
  const pairing = await env.DB.prepare(`SELECT pairing_id, workspace_id, creator_device_id, source_epoch, state, claim_id, claim_token_hash, recipient_name, recipient_public_key, approved_device_id, delivery_ciphertext, expires_at FROM pairings WHERE pairing_id = ? AND ${column} = ? AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = pairings.workspace_id AND source_epoch = pairings.source_epoch) AND (? = 0 OR state != 'approved' OR EXISTS (SELECT 1 FROM devices WHERE device_id = pairings.approved_device_id AND workspace_id = pairings.workspace_id AND revoked_at IS NULL))`)
    .bind(pairingId, await sha256(token), requireClaim ? 1 : 0).first<Pairing>();
  if (!pairing || pairing.expires_at <= now()) return null;
  return pairing;
}
async function encryptionKey(env: Env): Promise<CryptoKey | null> {
  const bytes = env.DELIVERY_ENCRYPTION_KEY ? base64urlBytes(env.DELIVERY_ENCRYPTION_KEY) : null;
  if (!bytes || bytes.length !== 32) return null;
  return crypto.subtle.importKey("raw", ownedBuffer(bytes), "AES-GCM", false, ["encrypt", "decrypt"]);
}
export async function encryptStored(env: Env, value: Record<string, string>): Promise<string | null> {
  const key = await encryptionKey(env); if (!key) return null;
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = encoder.encode(JSON.stringify(value));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: ownedBuffer(iv) }, key, ownedBuffer(plaintext)));
  const pack = (bytes: Uint8Array) => {
    let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  };
  return JSON.stringify({ v: 1, iv: pack(iv), ciphertext: pack(ciphertext) });
}
async function decryptStored(env: Env, packed: string): Promise<Record<string, string> | null> {
  const key = await encryptionKey(env); if (!key) return null;
  try {
    const container: unknown = JSON.parse(packed);
    if (!isRecord(container) || container.v !== 1 || !stringField(container.iv, 64, keyPattern) || !stringField(container.ciphertext, 8192, keyPattern)) return null;
    const iv = base64urlBytes(container.iv), ciphertext = base64urlBytes(container.ciphertext);
    if (!iv || iv.length !== 12 || !ciphertext) return null;
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: ownedBuffer(iv) }, key, ownedBuffer(ciphertext));
    const stored: unknown = JSON.parse(new TextDecoder().decode(plaintext));
    return isRecord(stored) && Object.keys(stored).length <= 16 && Object.values(stored).every((value) => stringField(value, 4096)) ? stored as Record<string, string> : null;
  } catch { return null; }
}
async function encryptDelivery(env: Env, value: Record<string, string>): Promise<string | null> { return encryptStored(env, value); }
async function decryptDelivery(env: Env, packed: string): Promise<Record<string, string> | null> {
  const delivery = await decryptStored(env, packed);
  const required = ["deviceId", "deviceToken", "wrappedSnapshotKey", "sourcePublicKey", "workspaceId", "sourceDeviceId", "sourceEpoch", "keyId"];
  return delivery && required.every((field) => stringField(delivery[field], 4096)) ? delivery : null;
}
export async function decryptActivityToken(env: Env, packed: string): Promise<string | null> {
  const value = await decryptStored(env, packed);
  return value && Object.keys(value).length === 1 && stringField(value.token, 1024) ? value.token : null;
}
function encodeBase64url(bytes: Uint8Array): string { let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte); return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, ""); }
export class ApnsTransport implements PushTransport {
  private sharedToken: Promise<string | null> | null = null;
  constructor(private readonly env: Env) {}
  private async providerToken(team: string, keyId: string, pem: string): Promise<string | null> {
    const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----|\s/g, "");
    const keyBytes = base64urlBytes(body.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
    if (!keyBytes) return null;
    const fingerprint = await sha256(JSON.stringify([team, keyId, encodeBase64url(keyBytes)]));
    for (let attempt = 0; attempt < 20; attempt++) {
      const currentTime = Date.now();
      const cached = await this.env.DB.prepare("SELECT token_ciphertext, issued_at_ms FROM apns_provider_token_cache WHERE key_fingerprint = ?")
        .bind(fingerprint).first<{ token_ciphertext: string | null; issued_at_ms: number | null }>();
      if (cached?.token_ciphertext && cached.issued_at_ms !== null && cached.issued_at_ms > currentTime - apnsTokenLifetimeMs && cached.issued_at_ms <= currentTime + 120_000) {
        const value = await decryptStored(this.env, cached.token_ciphertext);
        if (value && Object.keys(value).length === 1 && stringField(value.jwt, 4096, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/)) return value.jwt;
        // A rotated delivery key cannot decrypt the old cache. Wait for its
        // normal refresh window so the same APNs signing key is not updated early.
        return null;
      }
      const lease = randomId();
      const claimed = await this.env.DB.prepare("INSERT INTO apns_provider_token_cache(key_fingerprint, token_ciphertext, issued_at_ms, lease_id, lease_until_ms) VALUES(?, NULL, NULL, ?, ?) ON CONFLICT(key_fingerprint) DO UPDATE SET lease_id = excluded.lease_id, lease_until_ms = excluded.lease_until_ms WHERE (apns_provider_token_cache.lease_until_ms IS NULL OR apns_provider_token_cache.lease_until_ms <= ?) AND (apns_provider_token_cache.issued_at_ms IS NULL OR apns_provider_token_cache.issued_at_ms <= ? OR apns_provider_token_cache.issued_at_ms > ?)")
        .bind(fingerprint, lease, currentTime + apnsTokenLeaseMs, currentTime, currentTime - apnsTokenLifetimeMs, currentTime + 120_000).run();
      if ((claimed.meta.changes ?? 0) === 1) {
        let savedToken = false;
        try {
          const issuedAt = Math.floor(Date.now() / 1000);
          const key = await crypto.subtle.importKey("pkcs8", ownedBuffer(keyBytes), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
          const header = encodeBase64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
          const claims = encodeBase64url(encoder.encode(JSON.stringify({ iss: team, iat: issuedAt })));
          const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${header}.${claims}`));
          const jwt = `${header}.${claims}.${encodeBase64url(new Uint8Array(signature))}`;
          const sealed = await encryptStored(this.env, { jwt });
          if (sealed) {
            const saved = await this.env.DB.prepare("UPDATE apns_provider_token_cache SET token_ciphertext = ?, issued_at_ms = ?, lease_id = NULL, lease_until_ms = NULL WHERE key_fingerprint = ? AND lease_id = ?")
              .bind(sealed, issuedAt * 1000, fingerprint, lease).run();
            if ((saved.meta.changes ?? 0) === 1) { savedToken = true; return jwt; }
          }
        } finally {
          if (!savedToken) await this.env.DB.prepare("UPDATE apns_provider_token_cache SET lease_id = NULL, lease_until_ms = NULL WHERE key_fingerprint = ? AND lease_id = ?")
            .bind(fingerprint, lease).run();
        }
        return null;
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    return null;
  }
  async send(token: string, environment: "sandbox" | "production", payload: unknown, style: "liveactivity" | "alert" = "liveactivity"): Promise<PushResult | null> {
    const { APNS_TEAM_ID: team, APNS_KEY_ID: keyId, APNS_PRIVATE_KEY: pem, APNS_TOPIC: topic } = this.env;
    if (!team || !keyId || !pem || !topic) return null;
    try {
      const jwt = await (this.sharedToken ??= this.providerToken(team, keyId, pem)); if (!jwt) return null;
      const host = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
      const headers = style === "alert"
        ? { authorization: `bearer ${jwt}`, "apns-push-type": "alert", "apns-topic": topic, "apns-priority": "10", "content-type": "application/json" }
        : { authorization: `bearer ${jwt}`, "apns-push-type": "liveactivity", "apns-topic": `${topic}.push-type.liveactivity`, "apns-priority": "5", "content-type": "application/json" };
      const response = await fetch(`${host}/3/device/${encodeURIComponent(token)}`, { method: "POST", headers, body: JSON.stringify(payload) });
      return { status: response.status };
    } catch { return null; }
  }
}
async function workspace(env: Env, workspaceId: string): Promise<Workspace | null> {
  return env.DB.prepare("SELECT workspace_id, writer_device_id, source_epoch, source_public_key FROM workspaces WHERE workspace_id = ?").bind(workspaceId).first<Workspace>();
}
async function expirePairings(env: Env): Promise<void> {
  await env.DB.prepare("UPDATE pairings SET state = 'rejected', delivery_ciphertext = NULL WHERE pairing_id IN (SELECT pairing_id FROM pairings WHERE expires_at <= ? AND state IN ('pending', 'claimed', 'approved') LIMIT 32)").bind(now()).run();
}
async function allowed(request: Request, env: Env, scope: string): Promise<boolean> {
  const windowStartedAt = Math.floor(Date.now() / 60_000) * 60_000;
  const identity = request.headers.get("cf-connecting-ip") ?? "anonymous";
  const bucket = `${scope}:${await sha256(identity)}`;
  await env.DB.prepare("DELETE FROM rate_limits WHERE bucket IN (SELECT bucket FROM rate_limits WHERE window_started_at < ? LIMIT 32)").bind(windowStartedAt - 10 * 60_000).run();
  await env.DB.prepare("INSERT INTO rate_limits(bucket, window_started_at, count) VALUES(?, ?, 0) ON CONFLICT(bucket) DO NOTHING").bind(bucket, windowStartedAt).run();
  const updated = await env.DB.prepare("UPDATE rate_limits SET count = CASE WHEN window_started_at = ? THEN count + 1 ELSE 1 END, window_started_at = ? WHERE bucket = ? AND (window_started_at != ? OR count < 30)").bind(windowStartedAt, windowStartedAt, bucket, windowStartedAt).run();
  return (updated.meta.changes ?? 0) === 1;
}
function routePath(pathname: string): { pairingId?: string; deviceId?: string; activityId?: string; action?: string } {
  const pairing = /^\/v1\/pairings\/([A-Za-z0-9_-]{1,80})(?:\/(claim|approve|result|ack))?$/.exec(pathname);
  if (pairing) return { pairingId: pairing[1], action: pairing[2] };
  const device = /^\/v1\/devices\/([A-Za-z0-9_-]{1,80})$/.exec(pathname);
  if (device) return { deviceId: device[1] };
  const activity = /^\/v1\/activities\/([A-Za-z0-9_-]{1,80})$/.exec(pathname);
  return activity ? { activityId: activity[1] } : {};
}
function rateScope(method: string, pathname: string, route: ReturnType<typeof routePath>): string | null {
  const fixed: Record<string, readonly string[]> = {
    "/mcp": ["POST"],
    "/v1/mcp-access": ["PUT", "DELETE"],
    "/v1/mcp-snapshot": ["PUT"],
    "/v1/bootstrap": ["POST"],
    "/v1/pairings": ["POST"],
    "/v1/snapshot": ["GET", "PUT"],
    "/v1/usage": ["GET", "PUT"],
    "/v1/source-key-rotations": ["POST"],
    "/v1/device-key-wrap": ["GET"],
    "/v1/live-projections": ["PUT"],
    "/v1/alert-token": ["PUT", "DELETE"],
    "/v1/alert-settings": ["PUT"],
    "/v1/alert-push": ["POST"],
    "/v1/devices": ["GET"],
    "/v1/shares": ["GET", "POST"],
  };
  if (fixed[pathname]?.includes(method)) return `${method}:${pathname}`;
  const pairingMethods: Record<string, string> = { claim: "POST", approve: "POST", result: "GET", ack: "POST" };
  if (route.pairingId && method === (route.action ? pairingMethods[route.action] : "GET"))
    return `${method}:/v1/pairings/{pairingId}${route.action ? `/${route.action}` : ""}`;
  if (route.deviceId && method === "DELETE") return `${method}:/v1/devices/{deviceId}`;
  if (route.activityId && (method === "PUT" || method === "DELETE")) return `${method}:/v1/activities/{activityId}`;
  const share = /^\/v1\/shares\/[A-Za-z0-9_-]{1,80}(?:\/(claim|approve|result|projection))?$/.exec(pathname);
  const shareMethods: Record<string, readonly string[]> = { claim: ["POST"], approve: ["POST"], result: ["GET"], projection: ["GET", "PUT"] };
  if (share && (share[1] ? shareMethods[share[1]]?.includes(method) : method === "DELETE"))
    return `${method}:/v1/shares/{shareId}${share[1] ? `/${share[1]}` : ""}`;
  return null;
}

type BootstrapCredential = { token: string; legacy: boolean };
const maxBootstrapTenants = 128;

/// `BOOTSTRAP_SECRET` remains the legacy single-tenant credential.
/// `BOOTSTRAP_SECRETS` (JSON array of strings) provisions one workspace per
/// token, so one hosted Worker can onboard independent users. The cap applies
/// to listed tokens only; the legacy entry does not consume a slot.
function bootstrapCredentials(env: Env): BootstrapCredential[] {
  const credentials: BootstrapCredential[] = [];
  if (env.BOOTSTRAP_SECRET) credentials.push({ token: env.BOOTSTRAP_SECRET, legacy: true });
  let listed: unknown = undefined;
  if (env.BOOTSTRAP_SECRETS) { try { listed = JSON.parse(env.BOOTSTRAP_SECRETS); } catch { listed = undefined; } }
  const values = Array.isArray(listed) ? listed : [];
  let listedCount = 0;
  for (const value of values) {
    if (listedCount >= maxBootstrapTenants) break;
    if (typeof value !== "string" || value.length === 0 || value.length > 2048) continue;
    if (credentials.some((entry) => safeConfigEqual(entry.token, value))) continue;
    credentials.push({ token: value, legacy: false });
    listedCount += 1;
  }
  return credentials;
}

async function bootstrap(request: Request, env: Env): Promise<Response> {
  if (env.BOOTSTRAP_ENABLED !== "true") return problem(403, "bootstrap_disabled");
  const bootstrapToken = request.headers.get("x-bootstrap-token") ?? undefined;
  const credential = bootstrapCredentials(env).find((entry) => safeConfigEqual(bootstrapToken, entry.token));
  if (!credential) return problem(401, "invalid_credential");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["deviceName", "sourcePublicKey", "requestId"]) || !stringField(body.deviceName, 48) || !rawPublicKey(body.sourcePublicKey) || (body.requestId !== undefined && !stringField(body.requestId, 80, idPattern))) return problem(400, "invalid_request");
  const requestId = body.requestId as string | undefined;
  const tokenHash = await sha256(bootstrapToken!);
  const replayResponse = async (): Promise<Response | null> => {
    if (!requestId) return null;
    await env.DB.prepare("DELETE FROM bootstrap_replays WHERE request_id IN (SELECT request_id FROM bootstrap_replays WHERE expires_at <= ? LIMIT 32)").bind(now()).run();
    const existing = await env.DB.prepare("SELECT bootstrap_token_hash, device_name, source_public_key FROM bootstrap_replays WHERE request_id = ?").bind(requestId).first<{ bootstrap_token_hash: string; device_name: string; source_public_key: string }>();
    if (existing && (existing.bootstrap_token_hash !== tokenHash || existing.device_name !== body.deviceName || existing.source_public_key !== body.sourcePublicKey)) return problem(409, "bootstrap_request_mismatch");
    if (existing) {
      const replay = await env.DB.prepare("SELECT replay.response_ciphertext FROM bootstrap_replays AS replay JOIN workspaces AS workspace ON workspace.workspace_id = replay.workspace_id AND workspace.writer_device_id = replay.device_id AND workspace.source_epoch = replay.source_epoch AND workspace.source_public_key = replay.source_public_key JOIN devices AS device ON device.device_id = replay.device_id AND device.workspace_id = replay.workspace_id AND device.role = 'writer' AND device.revoked_at IS NULL WHERE replay.request_id = ? AND replay.bootstrap_token_hash = ? AND replay.expires_at > ?").bind(requestId, tokenHash, now()).first<{ response_ciphertext: string }>();
      if (!replay) return problem(409, "bootstrap_replay_unavailable");
      const response = await decryptStored(env, replay.response_ciphertext);
      if (!response || !stringField(response.workspaceId, 80, idPattern) || !stringField(response.deviceId, 80, idPattern) || !stringField(response.deviceToken, 256) || !stringField(response.sourceEpoch, 80, idPattern)) return problem(503, "bootstrap_replay_unavailable");
      return json(response as BootstrapResponse);
    }
    return null;
  };
  const existingResponse = await replayResponse(); if (existingResponse) return existingResponse;
  // Deployments that bootstrapped before 0009 own the single legacy workspace;
  // the singleton row blocks the legacy secret while per-tenant tokens keep working.
  if (credential.legacy) {
    const legacy = await env.DB.prepare("SELECT completed_at FROM bootstrap_state WHERE singleton = 1").first();
    if (legacy) return problem(409, "bootstrap_already_completed");
  }
  const workspaceId = randomId(), deviceId = randomId(), sourceEpoch = randomId(), deviceToken = randomToken(), createdAt = now();
  const response: BootstrapResponse = { workspaceId, deviceId, deviceToken, sourceEpoch };
  const responseCiphertext = requestId ? await encryptStored(env, response) : null;
  if (requestId && !responseCiphertext) return problem(503, "delivery_secret_unavailable");
  try {
    const statements = [
      env.DB.prepare("INSERT INTO bootstrap_tenants(bootstrap_token_hash, workspace_id, completed_at) VALUES(?, ?, ?)").bind(tokenHash, workspaceId, createdAt),
      env.DB.prepare("INSERT INTO workspaces(workspace_id, writer_device_id, source_epoch, source_public_key, created_at) VALUES(?, ?, ?, ?, ?)").bind(workspaceId, deviceId, sourceEpoch, body.sourcePublicKey, createdAt),
      env.DB.prepare("INSERT INTO devices(device_id, workspace_id, role, name, token_hash, created_at) VALUES(?, ?, 'writer', ?, ?, ?)").bind(deviceId, workspaceId, body.deviceName, await sha256(deviceToken), createdAt),
    ];
    if (requestId && responseCiphertext) statements.push(env.DB.prepare("INSERT INTO bootstrap_replays(request_id, bootstrap_token_hash, device_name, source_public_key, workspace_id, device_id, source_epoch, response_ciphertext, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").bind(requestId, tokenHash, body.deviceName, body.sourcePublicKey, workspaceId, deviceId, sourceEpoch, responseCiphertext, new Date(Date.now() + pairingLifetimeMs).toISOString(), createdAt));
    // Keep the legacy credential single-workspace across secret rotation on
    // deployments that never wrote the pre-0009 singleton row.
    if (credential.legacy) statements.push(env.DB.prepare("INSERT INTO bootstrap_state(singleton, completed_at) VALUES(1, ?)").bind(createdAt));
    await env.DB.batch(statements);
  } catch {
    const replay = await replayResponse(); if (replay) return replay;
    return problem(409, "bootstrap_already_completed");
  }
  return json(response);
}

async function createPairing(request: Request, env: Env, device: Device): Promise<Response> {
  if (device.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["pairingSecretHash"]) || !stringField(body.pairingSecretHash, 64, hashPattern)) return problem(400, "invalid_request");
  const pairingId = randomId(); const expiresAt = new Date(Date.now() + pairingLifetimeMs).toISOString();
  const created = await env.DB.prepare("INSERT INTO pairings(pairing_id, workspace_id, creator_device_id, source_epoch, pairing_secret_hash, state, expires_at, created_at) SELECT ?, ?, ?, source_epoch, ?, 'pending', ?, ? FROM workspaces WHERE workspace_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL)")
    .bind(pairingId, device.workspace_id, device.device_id, body.pairingSecretHash, expiresAt, now(), device.workspace_id, device.device_id, device.workspace_id, device.token_hash).run();
  if ((created.meta.changes ?? 0) !== 1) return problem(401, "invalid_credential");
  return json({ pairingId, expiresAt });
}

async function claimPairing(request: Request, env: Env, pairingId: string): Promise<Response> {
  const pairing = await pairingCapability(request, env, pairingId, false); if (!pairing) return problem(401, "invalid_or_expired_pairing_capability");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["deviceName", "recipientPublicKey"]) || !stringField(body.deviceName, 48) || !rawPublicKey(body.recipientPublicKey)) return problem(400, "invalid_request");
  const claimId = randomId(), claimToken = randomToken();
  const result = await env.DB.prepare("UPDATE pairings SET state = 'claimed', claim_id = ?, claim_token_hash = ?, recipient_name = ?, recipient_public_key = ? WHERE pairing_id = ? AND workspace_id = ? AND state = 'pending' AND expires_at > ?")
    .bind(claimId, await sha256(claimToken), body.deviceName, body.recipientPublicKey, pairingId, pairing.workspace_id, now()).run();
  if ((result.meta.changes ?? 0) !== 1) return problem(409, "pairing_not_pending");
  return json({ claimId, claimToken, state: "claimed" });
}

async function inspectPairing(env: Env, device: Device, pairingId: string): Promise<Response> {
  if (device.role !== "writer") return problem(403, "role_forbidden");
  const pairing = await env.DB.prepare("SELECT pairing_id, workspace_id, creator_device_id, state, claim_id, claim_token_hash, recipient_name, recipient_public_key, approved_device_id, delivery_ciphertext, expires_at FROM pairings WHERE pairing_id = ? AND workspace_id = ?")
    .bind(pairingId, device.workspace_id).first<Pairing>();
  if (!pairing) return problem(404, "pairing_not_found");
  return json({ state: pairing.expires_at <= now() && pairing.state !== "consumed" ? "expired" : pairing.state, claimId: pairing.claim_id, deviceName: pairing.recipient_name, recipientPublicKey: pairing.recipient_public_key, expiresAt: pairing.expires_at });
}

async function approvePairing(request: Request, env: Env, device: Device, pairingId: string): Promise<Response> {
  if (device.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["claimId", "wrappedSnapshotKey", "keyId", "sourcePublicKey"]) || !stringField(body.claimId, 80, idPattern) || !stringField(body.wrappedSnapshotKey, 4096) || !stringField(body.keyId, 80, idPattern) || !rawPublicKey(body.sourcePublicKey)) return problem(400, "invalid_request");
  const pairing = await env.DB.prepare("SELECT pairing_id, workspace_id, creator_device_id, source_epoch, state, claim_id, claim_token_hash, recipient_name, recipient_public_key, approved_device_id, delivery_ciphertext, expires_at FROM pairings WHERE pairing_id = ? AND workspace_id = ? AND creator_device_id = ?")
    .bind(pairingId, device.workspace_id, device.device_id).first<Pairing>();
  const source = await workspace(env, device.workspace_id);
  if (!pairing || !source || pairing.source_epoch !== source.source_epoch || pairing.claim_id !== body.claimId || pairing.state !== "claimed" || pairing.expires_at <= now()) return problem(409, "pairing_not_claimed");
  if (source.source_public_key !== body.sourcePublicKey) return problem(409, "source_key_mismatch");
  const viewerDeviceId = randomId(), viewerToken = randomToken();
  const delivery = await encryptDelivery(env, { deviceId: viewerDeviceId, deviceToken: viewerToken, wrappedSnapshotKey: body.wrappedSnapshotKey, sourcePublicKey: source.source_public_key, workspaceId: source.workspace_id, sourceDeviceId: source.writer_device_id, sourceEpoch: source.source_epoch, keyId: body.keyId });
  if (!delivery) return problem(503, "delivery_secret_unavailable");
  // These two statements are a D1 batch transaction. The state transition is the authorization decision.
  const approved = await env.DB.batch([
    env.DB.prepare("UPDATE pairings SET state = 'approved', approved_device_id = ?, delivery_ciphertext = ?, approved_at = ? WHERE pairing_id = ? AND workspace_id = ? AND claim_id = ? AND state = 'claimed' AND expires_at > ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = pairings.workspace_id AND source_epoch = pairings.source_epoch)")
      .bind(viewerDeviceId, delivery, now(), pairingId, device.workspace_id, body.claimId, now(), device.device_id, device.workspace_id, device.token_hash),
    env.DB.prepare("INSERT INTO devices(device_id, workspace_id, role, name, token_hash, recipient_public_key, created_at) SELECT ?, ?, 'viewer', ?, ?, recipient_public_key, ? FROM pairings WHERE pairing_id = ? AND workspace_id = ? AND claim_id = ? AND state = 'approved' AND approved_device_id = ?")
      .bind(viewerDeviceId, device.workspace_id, pairing.recipient_name, await sha256(viewerToken), now(), pairingId, device.workspace_id, body.claimId, viewerDeviceId),
  ]);
  if ((approved[0]?.meta.changes ?? 0) !== 1 || (approved[1]?.meta.changes ?? 0) !== 1) return problem(409, "pairing_approval_conflict");
  return json({ state: "approved" });
}

async function pairingResult(request: Request, env: Env, pairingId: string): Promise<Response> {
  const pairing = await pairingCapability(request, env, pairingId, true); if (!pairing) return problem(401, "invalid_or_expired_claim_capability");
  if (pairing.state === "approved" && pairing.delivery_ciphertext) {
    const delivery = await decryptDelivery(env, pairing.delivery_ciphertext);
    if (!delivery) return problem(503, "delivery_unavailable");
    return json({ state: "approved", ...delivery });
  }
  return json({ state: pairing.state, deviceId: null, deviceToken: null, wrappedSnapshotKey: null, sourcePublicKey: null, workspaceId: null, sourceDeviceId: null, sourceEpoch: null, keyId: null });
}

async function acknowledgePairing(request: Request, env: Env, pairingId: string): Promise<Response> {
  const pairing = await pairingCapability(request, env, pairingId, true); if (!pairing) return problem(401, "invalid_or_expired_claim_capability");
  const body = await readJson(request);
  if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["claimId"]) || !stringField(body.claimId, 80, idPattern) || pairing.claim_id !== body.claimId) return problem(400, "invalid_request");
  if (pairing.state === "consumed") return json({ ok: true });
  const result = await env.DB.prepare("UPDATE pairings SET state = 'consumed', delivery_ciphertext = NULL, consumed_at = ? WHERE pairing_id = ? AND claim_id = ? AND state = 'approved' AND expires_at > ?")
    .bind(now(), pairingId, body.claimId, now()).run();
  return (result.meta.changes ?? 0) === 1 ? json({ ok: true }) : problem(409, "pairing_not_approved");
}

async function listDevices(env: Env, device: Device): Promise<Response> {
  if (device.role !== "writer") return problem(403, "role_forbidden");
  const rows = await env.DB.prepare("SELECT device_id, name, role, revoked_at, recipient_public_key FROM devices WHERE workspace_id = ? ORDER BY created_at ASC").bind(device.workspace_id).run<{ device_id: string; name: string; role: Role; revoked_at: string | null; recipient_public_key: string | null }>();
  return json(rows.results.map((row) => ({ deviceId: row.device_id, name: row.name, role: row.role, revoked: row.revoked_at !== null, recipientPublicKey: row.recipient_public_key })));
}

async function revokeDevice(env: Env, actor: Device, targetId: string): Promise<Response> {
  const target = await env.DB.prepare("SELECT device_id, workspace_id, role, name, token_hash FROM devices WHERE device_id = ? AND workspace_id = ?").bind(targetId, actor.workspace_id).first<Device>();
  if (!target) return problem(404, "device_not_found");
  if (actor.role !== "writer" && actor.device_id !== targetId) return problem(403, "role_forbidden");
  if (actor.role === "writer" && target.role !== "viewer") return problem(403, "writer_may_only_revoke_viewer");
  const revoked = await env.DB.prepare("UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE device_id = ? AND workspace_id = ? AND EXISTS (SELECT 1 FROM devices AS actor WHERE actor.device_id = ? AND actor.workspace_id = ? AND actor.token_hash = ? AND actor.revoked_at IS NULL)").bind(now(), targetId, actor.workspace_id, actor.device_id, actor.workspace_id, actor.token_hash).run();
  if ((revoked.meta.changes ?? 0) !== 1) return problem(401, "invalid_credential");
  return json({ ok: true });
}

function snapshotEnvelope(value: Record<string, unknown>): Envelope | null {
  const keys = ["schemaVersion", "workspaceId", "sourceDeviceId", "sourceEpoch", "sequence", "keyId", "nonce", "ciphertext", "tag", "signature", "contentHash"];
  if (!hasOnly(value, keys) || Object.keys(value).length !== keys.length || value.schemaVersion !== "1.0.0" || !stringField(value.workspaceId, 80, idPattern) || !stringField(value.sourceDeviceId, 80, idPattern) || !stringField(value.sourceEpoch, 80, idPattern) || !stringField(value.keyId, 80, idPattern) || !Number.isSafeInteger(value.sequence) || (value.sequence as number) < 1 || (value.sequence as number) > Number.MAX_SAFE_INTEGER || !stringField(value.nonce, 16, keyPattern) || (value.nonce as string).length !== 16 || !stringField(value.ciphertext, 192000, keyPattern) || !stringField(value.tag, 22, keyPattern) || (value.tag as string).length !== 22 || !stringField(value.signature, 86, keyPattern) || (value.signature as string).length !== 86 || !stringField(value.contentHash, 64, hashPattern)) return null;
  const nonce = base64urlBytes(value.nonce as string), tag = base64urlBytes(value.tag as string), signature = base64urlBytes(value.signature as string), ciphertext = base64urlBytes(value.ciphertext as string);
  return nonce?.length === 12 && tag?.length === 16 && signature?.length === 64 && ciphertext ? value as Envelope : null;
}
async function validEnvelope(envelope: Envelope, source: Workspace, writer: Device, domain: "QI" | "QI-USAGE" = "QI"): Promise<boolean> {
  if (envelope.workspaceId !== source.workspace_id || envelope.sourceDeviceId !== writer.device_id || envelope.sourceEpoch !== source.source_epoch) return false;
  const nonce = base64urlBytes(envelope.nonce), ciphertext = base64urlBytes(envelope.ciphertext), tag = base64urlBytes(envelope.tag), signature = base64urlBytes(envelope.signature), publicKey = base64urlBytes(source.source_public_key);
  if (!nonce || !ciphertext || !tag || !signature || !publicKey || publicKey.length !== 32) return false;
  const header = `${domain}|1|${envelope.workspaceId}|${envelope.sourceDeviceId}|${envelope.sourceEpoch}|${envelope.sequence}|${envelope.keyId}`;
  const signed = concatBytes(encoder.encode(header), encoder.encode("\n"), nonce, ciphertext, tag);
  if (await sha256Bytes(signed) !== envelope.contentHash) return false;
  try {
    const key = await crypto.subtle.importKey("raw", ownedBuffer(publicKey), { name: "Ed25519" }, false, ["verify"]);
    return crypto.subtle.verify({ name: "Ed25519" }, key, ownedBuffer(signature), ownedBuffer(signed));
  } catch { return false; }
}
async function cleanupSnapshots(env: Env): Promise<void> {
  const current = now();
  await env.DB.prepare("DELETE FROM snapshots WHERE workspace_id IN (SELECT workspace_id FROM snapshots WHERE expires_at <= ? LIMIT 32)").bind(current).run();
  await env.DB.prepare("DELETE FROM snapshot_receipts WHERE server_revision IN (SELECT server_revision FROM snapshot_receipts WHERE expires_at <= ? LIMIT 32)").bind(current).run();
}
function receipt(row: { server_revision: number; source_sequence: number; received_at: string; content_hash: string }): Receipt {
  return { serverRevision: row.server_revision, sourceSequence: row.source_sequence, receivedAt: row.received_at, serverTime: row.received_at, contentHash: row.content_hash };
}
async function putSnapshot(request: Request, env: Env, writer: Device): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request, snapshotBodyLimit);
  if (body === "too_large") return problem(413, "payload_too_large");
  const envelope = body && snapshotEnvelope(body); if (!envelope) return problem(400, "invalid_envelope");
  const source = await workspace(env, writer.workspace_id);
  if (!source || !(await validEnvelope(envelope, source, writer))) return problem(403, "invalid_source_proof");
  const receivedAt = now(), expiresAt = new Date(Date.now() + snapshotLifetimeMs).toISOString(), storedEnvelope = JSON.stringify(envelope);
  const admitted = await env.DB.batch([
    env.DB.prepare("INSERT INTO snapshot_receipts(workspace_id, source_epoch, source_sequence, content_hash, received_at, expires_at) SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND writer_device_id = ? AND source_epoch = ?) AND NOT EXISTS (SELECT 1 FROM snapshot_receipts WHERE workspace_id = ? AND source_epoch = ? AND source_sequence = ?) AND (NOT EXISTS (SELECT 1 FROM snapshots WHERE workspace_id = ?) OR ? != (SELECT source_epoch FROM snapshots WHERE workspace_id = ?) OR ? > (SELECT source_sequence FROM snapshots WHERE workspace_id = ?))")
      .bind(writer.workspace_id, envelope.sourceEpoch, envelope.sequence, envelope.contentHash, receivedAt, expiresAt, writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, writer.device_id, envelope.sourceEpoch, writer.workspace_id, envelope.sourceEpoch, envelope.sequence, writer.workspace_id, envelope.sourceEpoch, writer.workspace_id, envelope.sequence, writer.workspace_id),
    env.DB.prepare("INSERT INTO snapshots(workspace_id, source_device_id, source_epoch, source_sequence, content_hash, envelope_json, server_revision, received_at, expires_at) SELECT ?, ?, ?, ?, ?, ?, server_revision, ?, ? FROM snapshot_receipts WHERE workspace_id = ? AND source_epoch = ? AND source_sequence = ? AND content_hash = ? ON CONFLICT(workspace_id) DO UPDATE SET source_device_id = excluded.source_device_id, source_epoch = excluded.source_epoch, source_sequence = excluded.source_sequence, content_hash = excluded.content_hash, envelope_json = excluded.envelope_json, server_revision = excluded.server_revision, received_at = excluded.received_at, expires_at = excluded.expires_at WHERE excluded.source_epoch != snapshots.source_epoch OR excluded.source_sequence > snapshots.source_sequence")
      .bind(writer.workspace_id, writer.device_id, envelope.sourceEpoch, envelope.sequence, envelope.contentHash, storedEnvelope, receivedAt, expiresAt, writer.workspace_id, envelope.sourceEpoch, envelope.sequence, envelope.contentHash),
  ]);
  const stored = await env.DB.prepare("SELECT receipt.server_revision, receipt.source_sequence, receipt.received_at, receipt.content_hash FROM snapshot_receipts AS receipt WHERE receipt.workspace_id = ? AND receipt.source_epoch = ? AND receipt.source_sequence = ? AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = receipt.workspace_id AND source_epoch = receipt.source_epoch)").bind(writer.workspace_id, envelope.sourceEpoch, envelope.sequence).first<{ server_revision: number; source_sequence: number; received_at: string; content_hash: string }>();
  if (!stored) {
    const active = await env.DB.prepare("SELECT device_id FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL").bind(writer.device_id, writer.workspace_id, writer.token_hash).first<{ device_id: string }>();
    return active ? problem(409, "old_sequence") : problem(401, "invalid_credential");
  }
  if ((admitted[0]?.meta.changes ?? 0) === 1) return json(receipt(stored));
  if (stored.content_hash === envelope.contentHash) return json(receipt(stored));
  return problem(409, "sequence_conflict");
}
async function getSnapshot(request: Request, env: Env, reader: Device): Promise<Response> {
  if (reader.role !== "viewer") return problem(403, "role_forbidden");
  const stored = await env.DB.prepare("SELECT snapshot.envelope_json, snapshot.source_sequence, snapshot.content_hash, snapshot.server_revision, snapshot.received_at, snapshot.expires_at FROM snapshots AS snapshot JOIN workspaces AS workspace ON workspace.workspace_id = snapshot.workspace_id AND workspace.source_epoch = snapshot.source_epoch WHERE snapshot.workspace_id = ? AND snapshot.expires_at > ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND revoked_at IS NULL)").bind(reader.workspace_id, now(), reader.device_id, reader.workspace_id, reader.token_hash).first<Snapshot>();
  if (!stored) {
    const active = await env.DB.prepare("SELECT device_id FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND revoked_at IS NULL").bind(reader.device_id, reader.workspace_id, reader.token_hash).first<{ device_id: string }>();
    return active ? problem(404, "snapshot_not_found") : problem(401, "invalid_credential");
  }
  const etag = `\"${stored.server_revision}\"`;
  if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers: { etag, "cache-control": "no-store", date: new Date().toUTCString() } });
  try { return new Response(JSON.stringify({ envelope: JSON.parse(stored.envelope_json), receipt: receipt(stored) }), { status: 200, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", date: new Date().toUTCString(), etag } }); } catch { return problem(500, "stored_snapshot_invalid"); }
}

// Usage is a separately authenticated sidecar; quota v1 bytes and limits do not change.
// Only the latest cumulative aggregate is stored. Its small replay watermark
// survives ciphertext expiry, so a deleted payload can never admit an older scan.
type UsageSnapshot = Omit<Snapshot, "envelope_json"> & { envelope_json: string | null; source_epoch: string };
async function cleanupUsage(env: Env): Promise<void> {
  await env.DB.prepare("UPDATE usage_snapshots SET envelope_json = NULL WHERE workspace_id IN (SELECT workspace_id FROM usage_snapshots WHERE expires_at <= ? AND envelope_json IS NOT NULL LIMIT 32)").bind(now()).run();
}
async function putUsage(request: Request, env: Env, writer: Device): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request, snapshotBodyLimit);
  if (body === "too_large") return problem(413, "payload_too_large");
  const envelope = body && snapshotEnvelope(body);
  if (!envelope) return problem(400, "invalid_envelope");
  // AES-GCM preserves plaintext length; enforce the 128 KiB aggregate limit
  // without asking the Worker to decrypt it.
  if ((base64urlBytes(envelope.ciphertext)?.length ?? Infinity) > 131072) return problem(413, "payload_too_large");
  const source = await workspace(env, writer.workspace_id);
  if (!source || source.writer_device_id !== writer.device_id || !(await validEnvelope(envelope, source, writer, "QI-USAGE"))) return problem(403, "invalid_source_proof");
  const receivedAt = now(), expiresAt = new Date(Date.now() + snapshotLifetimeMs).toISOString();
  await env.DB.prepare("INSERT INTO usage_snapshots(workspace_id, source_device_id, source_epoch, source_sequence, content_hash, envelope_json, server_revision, received_at, expires_at) SELECT ?, ?, ?, ?, ?, ?, 1, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND writer_device_id = ? AND source_epoch = ?) ON CONFLICT(workspace_id) DO UPDATE SET source_device_id = excluded.source_device_id, source_epoch = excluded.source_epoch, source_sequence = excluded.source_sequence, content_hash = excluded.content_hash, envelope_json = excluded.envelope_json, server_revision = usage_snapshots.server_revision + 1, received_at = excluded.received_at, expires_at = excluded.expires_at WHERE excluded.source_epoch != usage_snapshots.source_epoch OR excluded.source_sequence > usage_snapshots.source_sequence")
    .bind(writer.workspace_id, writer.device_id, envelope.sourceEpoch, envelope.sequence, envelope.contentHash, JSON.stringify(envelope), receivedAt, expiresAt, writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, writer.device_id, envelope.sourceEpoch).run();
  const stored = await env.DB.prepare("SELECT usage.source_epoch, usage.source_sequence, usage.content_hash, usage.server_revision, usage.received_at FROM usage_snapshots AS usage JOIN workspaces AS workspace ON workspace.workspace_id = usage.workspace_id AND workspace.source_epoch = usage.source_epoch AND workspace.writer_device_id = usage.source_device_id WHERE usage.workspace_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL)").bind(writer.workspace_id, writer.device_id, writer.workspace_id, writer.token_hash).first<UsageSnapshot>();
  if (!stored) {
    const active = await authenticateDevice(request, env);
    return active ? problem(409, "source_epoch_conflict") : problem(401, "invalid_credential");
  }
  if (stored.source_epoch !== envelope.sourceEpoch || stored.source_sequence > envelope.sequence) return problem(409, "old_sequence");
  if (stored.source_sequence !== envelope.sequence || stored.content_hash !== envelope.contentHash) return problem(409, "sequence_conflict");
  return json(receipt(stored));
}
async function getUsage(request: Request, env: Env, reader: Device): Promise<Response> {
  if (reader.role !== "viewer") return problem(403, "role_forbidden");
  const stored = await env.DB.prepare("SELECT usage.envelope_json, usage.source_epoch, usage.source_sequence, usage.content_hash, usage.server_revision, usage.received_at, usage.expires_at FROM usage_snapshots AS usage JOIN workspaces AS workspace ON workspace.workspace_id = usage.workspace_id AND workspace.source_epoch = usage.source_epoch AND workspace.writer_device_id = usage.source_device_id WHERE usage.workspace_id = ? AND usage.expires_at > ? AND usage.envelope_json IS NOT NULL AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND revoked_at IS NULL)").bind(reader.workspace_id, now(), reader.device_id, reader.workspace_id, reader.token_hash).first<UsageSnapshot>();
  if (!stored) {
    const active = await authenticateDevice(request, env);
    return active ? problem(404, "usage_not_found") : problem(401, "invalid_credential");
  }
  const etag = `"usage-${stored.server_revision}-${stored.content_hash}"`;
  const headers = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", date: new Date().toUTCString(), etag };
  if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers });
  try { return new Response(JSON.stringify({ envelope: JSON.parse(stored.envelope_json!), receipt: receipt(stored) }), { status: 200, headers }); }
  catch { return problem(500, "stored_usage_invalid"); }
}

async function verifySignature(publicKey: string, signature: string, message: Uint8Array): Promise<boolean> {
  const rawKey = base64urlBytes(publicKey), rawSignature = base64urlBytes(signature);
  if (!rawKey || rawKey.length !== 32 || !rawSignature || rawSignature.length !== 64) return false;
  try {
    const key = await crypto.subtle.importKey("raw", ownedBuffer(rawKey), { name: "Ed25519" }, false, ["verify"]);
    return crypto.subtle.verify({ name: "Ed25519" }, key, ownedBuffer(rawSignature), ownedBuffer(message));
  } catch { return false; }
}
function rotationRequest(value: Record<string, unknown>): Rotation | null {
  const keys = ["userConfirmation", "oldSourceEpoch", "newSourceEpoch", "newSourcePublicKey", "keyId", "wraps", "signature", "trustSignature"];
  if (!hasOnly(value, keys) || Object.keys(value).length !== keys.length || value.userConfirmation !== "rotate_source_key" || !stringField(value.oldSourceEpoch, 80, idPattern) || !stringField(value.newSourceEpoch, 80, idPattern) || value.oldSourceEpoch === value.newSourceEpoch || !rawPublicKey(value.newSourcePublicKey) || !stringField(value.keyId, 80, idPattern) || !stringField(value.signature, 86, keyPattern) || (value.signature as string).length !== 86 || !stringField(value.trustSignature, 86, keyPattern) || (value.trustSignature as string).length !== 86 || !Array.isArray(value.wraps) || value.wraps.length > 32) return null;
  const wraps: RotationWrap[] = [];
  for (const wrap of value.wraps) {
    if (!isRecord(wrap) || !hasOnly(wrap, ["deviceId", "wrappedSnapshotKey"]) || Object.keys(wrap).length !== 2 || !stringField(wrap.deviceId, 80, idPattern) || !stringField(wrap.wrappedSnapshotKey, 4096, keyPattern)) return null;
    wraps.push({ deviceId: wrap.deviceId, wrappedSnapshotKey: wrap.wrappedSnapshotKey });
  }
  return new Set(wraps.map((wrap) => wrap.deviceId)).size === wraps.length ? value as Rotation : null;
}
function wrapContext(workspaceId: string, sourceDeviceId: string, sourceEpoch: string, keyId: string, deviceId: string): string {
  return `${workspaceId}|${sourceDeviceId}|${sourceEpoch}|${keyId}|${deviceId}`;
}
async function validRotationWrap(wrap: RotationWrap, source: Workspace, rotation: Rotation, writer: Device): Promise<boolean> {
  const encodedWrap = base64urlBytes(wrap.wrappedSnapshotKey); if (!encodedWrap || encodedWrap.length > 3072) return false;
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(encodedWrap));
    if (!isRecord(value) || !hasOnly(value, ["version", "suite", "context", "encapsulatedKey", "ciphertext", "signature"]) || Object.keys(value).length !== 6 || value.version !== 1 || value.suite !== "X25519-HKDF-SHA256-AES256GCM" || value.context !== wrapContext(source.workspace_id, writer.device_id, rotation.newSourceEpoch, rotation.keyId, wrap.deviceId) || !stringField(value.encapsulatedKey, 43, keyPattern) || (value.encapsulatedKey as string).length !== 43 || !stringField(value.ciphertext, 64, keyPattern) || (value.ciphertext as string).length !== 64 || !stringField(value.signature, 86, keyPattern) || (value.signature as string).length !== 86) return false;
    const encapsulated = base64urlBytes(value.encapsulatedKey), ciphertext = base64urlBytes(value.ciphertext);
    if (!encapsulated || encapsulated.length !== 32 || !ciphertext || ciphertext.length !== 48) return false;
    return verifySignature(source.source_public_key, value.signature as string, concatBytes(encoder.encode(`QI-WRAP|1|${value.context}\n`), encapsulated, ciphertext));
  } catch { return false; }
}
async function rotateSourceKey(request: Request, env: Env, writer: Device): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request, snapshotBodyLimit);
  if (body === "too_large") return problem(413, "payload_too_large");
  const rotation = body && rotationRequest(body); if (!rotation) return problem(400, "invalid_rotation");
  const source = await workspace(env, writer.workspace_id);
  if (!source) return problem(409, "source_epoch_conflict");
  const wraps = [...rotation.wraps].sort((left, right) => left.deviceId < right.deviceId ? -1 : left.deviceId > right.deviceId ? 1 : 0);
  const header = `QI-ROTATE|1|${source.workspace_id}|${writer.device_id}|${rotation.oldSourceEpoch}|${rotation.newSourceEpoch}|${rotation.newSourcePublicKey}|${rotation.keyId}`;
  const signed = encoder.encode(`${header}\n${wraps.map((wrap) => `${wrap.deviceId}|${wrap.wrappedSnapshotKey}\n`).join("")}`);
  const messageHash = await sha256Bytes(signed);
  if (source.source_epoch !== rotation.oldSourceEpoch) {
    const replay = await env.DB.prepare("SELECT revision.server_revision, revision.source_epoch, revision.key_id FROM key_rotation_revisions AS revision WHERE revision.workspace_id = ? AND revision.old_source_epoch = ? AND revision.source_epoch = ? AND revision.key_id = ? AND revision.new_source_public_key = ? AND revision.rotation_message_hash = ? AND revision.rotation_signature = ? AND revision.trust_signature = ? AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = revision.workspace_id AND writer_device_id = ? AND source_epoch = revision.source_epoch) AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = revision.workspace_id AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL)").bind(writer.workspace_id, rotation.oldSourceEpoch, rotation.newSourceEpoch, rotation.keyId, rotation.newSourcePublicKey, messageHash, rotation.signature, rotation.trustSignature, writer.device_id, writer.device_id, writer.token_hash).first<{ server_revision: number; source_epoch: string; key_id: string }>();
    if (replay) return json({ workspaceId: writer.workspace_id, sourceEpoch: replay.source_epoch, keyId: replay.key_id, serverRevision: replay.server_revision });
    return problem(409, "source_epoch_conflict");
  }
  if (!(await verifySignature(source.source_public_key, rotation.signature, signed))) return problem(403, "invalid_rotation_signature");
  const trustHeader = `QI-ROTATION-TRUST|1|${source.workspace_id}|${writer.device_id}|${rotation.oldSourceEpoch}|${rotation.newSourceEpoch}|${rotation.newSourcePublicKey}|${rotation.keyId}`;
  if (!(await verifySignature(source.source_public_key, rotation.trustSignature, encoder.encode(trustHeader)))) return problem(403, "invalid_trust_signature");
  for (const wrap of wraps) if (!(await validRotationWrap(wrap, source, rotation, writer))) return problem(403, "invalid_device_wrap");
  const rotationId = randomId(), createdAt = now();
  const statements: D1PreparedStatement[] = [
    env.DB.prepare("INSERT INTO key_rotation_stages(rotation_id, workspace_id, old_source_epoch, new_source_epoch, new_source_public_key, key_id, created_at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND writer_device_id = ? AND source_epoch = ?)")
      .bind(rotationId, writer.workspace_id, rotation.oldSourceEpoch, rotation.newSourceEpoch, rotation.newSourcePublicKey, rotation.keyId, createdAt, writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, writer.device_id, rotation.oldSourceEpoch),
    ...wraps.map((wrap) => env.DB.prepare("INSERT INTO key_rotation_stage_wraps(rotation_id, device_id, wrapped_snapshot_key) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM key_rotation_stages WHERE rotation_id = ?)").bind(rotationId, wrap.deviceId, wrap.wrappedSnapshotKey, rotationId)),
    env.DB.prepare("INSERT INTO key_rotation_revisions(rotation_id, workspace_id, source_epoch, key_id, created_at, old_source_epoch, new_source_public_key, trust_signature, rotation_message_hash, rotation_signature) SELECT stage.rotation_id, stage.workspace_id, stage.new_source_epoch, stage.key_id, ?, stage.old_source_epoch, stage.new_source_public_key, ?, ?, ? FROM key_rotation_stages AS stage WHERE stage.rotation_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND role = 'writer' AND token_hash = ? AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = stage.workspace_id AND writer_device_id = ? AND source_epoch = stage.old_source_epoch) AND NOT EXISTS (SELECT 1 FROM devices AS viewer WHERE viewer.workspace_id = stage.workspace_id AND viewer.role = 'viewer' AND viewer.revoked_at IS NULL AND NOT EXISTS (SELECT 1 FROM key_rotation_stage_wraps WHERE rotation_id = stage.rotation_id AND device_id = viewer.device_id)) AND NOT EXISTS (SELECT 1 FROM key_rotation_stage_wraps AS wrap LEFT JOIN devices AS viewer ON viewer.device_id = wrap.device_id AND viewer.workspace_id = stage.workspace_id WHERE wrap.rotation_id = stage.rotation_id AND (viewer.device_id IS NULL OR viewer.role != 'viewer' OR viewer.revoked_at IS NOT NULL))")
      .bind(createdAt, rotation.trustSignature, messageHash, rotation.signature, rotationId, writer.device_id, writer.workspace_id, writer.token_hash, writer.device_id),
    env.DB.prepare("UPDATE workspaces SET source_epoch = (SELECT source_epoch FROM key_rotation_revisions WHERE rotation_id = ?), source_public_key = (SELECT new_source_public_key FROM key_rotation_stages WHERE rotation_id = ?) WHERE workspace_id = ? AND source_epoch = ? AND EXISTS (SELECT 1 FROM key_rotation_revisions WHERE rotation_id = ?)").bind(rotationId, rotationId, writer.workspace_id, rotation.oldSourceEpoch, rotationId),
    env.DB.prepare("INSERT INTO device_key_wraps(workspace_id, device_id, source_epoch, key_id, wrapped_snapshot_key, created_at) SELECT stage.workspace_id, wrap.device_id, stage.new_source_epoch, stage.key_id, wrap.wrapped_snapshot_key, ? FROM key_rotation_stages AS stage JOIN key_rotation_stage_wraps AS wrap ON wrap.rotation_id = stage.rotation_id WHERE stage.rotation_id = ? AND EXISTS (SELECT 1 FROM key_rotation_revisions WHERE rotation_id = ?)").bind(createdAt, rotationId, rotationId),
    env.DB.prepare("DELETE FROM key_rotation_stage_wraps WHERE rotation_id = ?").bind(rotationId),
    env.DB.prepare("DELETE FROM key_rotation_stages WHERE rotation_id = ?").bind(rotationId),
  ];
  await env.DB.batch(statements);
  const revision = await env.DB.prepare("SELECT server_revision, source_epoch, key_id FROM key_rotation_revisions WHERE rotation_id = ? AND workspace_id = ?").bind(rotationId, writer.workspace_id).first<{ server_revision: number; source_epoch: string; key_id: string }>();
  if (!revision) return problem(409, "rotation_not_admitted");
  return json({ workspaceId: writer.workspace_id, sourceEpoch: revision.source_epoch, keyId: revision.key_id, serverRevision: revision.server_revision });
}
async function getOwnDeviceKeyWrap(env: Env, viewer: Device): Promise<Response> {
  if (viewer.role !== "viewer") return problem(403, "role_forbidden");
  const wrap = await env.DB.prepare("SELECT wrap.source_epoch, wrap.key_id, wrap.wrapped_snapshot_key, revision.old_source_epoch, revision.new_source_public_key, revision.trust_signature, workspace.writer_device_id FROM device_key_wraps AS wrap JOIN workspaces AS workspace ON workspace.workspace_id = wrap.workspace_id JOIN key_rotation_revisions AS revision ON revision.workspace_id = wrap.workspace_id AND revision.source_epoch = wrap.source_epoch WHERE wrap.workspace_id = ? AND wrap.device_id = ? AND wrap.source_epoch = workspace.source_epoch AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'viewer' AND revoked_at IS NULL) ORDER BY wrap.created_at DESC LIMIT 1").bind(viewer.workspace_id, viewer.device_id, viewer.device_id, viewer.workspace_id, viewer.token_hash).first<{ source_epoch: string; key_id: string; wrapped_snapshot_key: string; old_source_epoch: string; new_source_public_key: string; trust_signature: string; writer_device_id: string }>();
  if (!wrap) return problem(404, "device_wrap_not_found");
  return json({ sourceEpoch: wrap.source_epoch, keyId: wrap.key_id, wrappedSnapshotKey: wrap.wrapped_snapshot_key, oldSourceEpoch: wrap.old_source_epoch, newSourcePublicKey: wrap.new_source_public_key, trustSignature: wrap.trust_signature, sourceDeviceId: wrap.writer_device_id });
}
export async function registerActivity(request: Request, env: Env, viewer: Device, activityId: string): Promise<Response> {
  if (viewer.role !== "viewer") return problem(403, "role_forbidden");
  const body = await readJson(request); if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["windowId", "activityToken", "environment", "endsAt", "projectionConsent"]) || !stringField(body.windowId, 80, idPattern) || !stringField(body.activityToken, 1024) || (body.environment !== "sandbox" && body.environment !== "production") || typeof body.projectionConsent !== "boolean" || typeof body.endsAt !== "string") return problem(400, "invalid_request");
  const end = Date.parse(body.endsAt); if (!Number.isFinite(end) || end <= Date.now() || end > Date.now() + activityLifetimeMs) return problem(400, "invalid_ends_at");
  const endsAt = new Date(end).toISOString();
  // Re-registration by the owning device refreshes the token and rolls the
  // deadline forward (never beyond +activityLifetimeMs), so a long session can
  // extend its own push coverage without a new activity id.
  const encrypted = await encryptDelivery(env, { token: body.activityToken }); if (!encrypted) return problem(503, "delivery_secret_unavailable");
  const results = await env.DB.batch([
    env.DB.prepare("INSERT INTO live_activities(activity_id, workspace_id, device_id, window_id, token_ciphertext, environment, ends_at, projection_consent, created_at, updated_at) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'viewer' AND revoked_at IS NULL) ON CONFLICT(activity_id) DO UPDATE SET token_ciphertext=excluded.token_ciphertext, environment=excluded.environment, ends_at=excluded.ends_at, projection_consent=excluded.projection_consent, disabled_at=NULL, backoff_until=NULL, last_sent_at=NULL, dispatch_lease=NULL, dispatching_until=NULL, updated_at=excluded.updated_at WHERE live_activities.workspace_id=excluded.workspace_id AND live_activities.device_id=excluded.device_id AND live_activities.window_id=excluded.window_id")
      .bind(activityId, viewer.workspace_id, viewer.device_id, body.windowId, encrypted, body.environment, endsAt, body.projectionConsent ? 1 : 0, now(), now(), viewer.device_id, viewer.workspace_id, viewer.token_hash),
    env.DB.prepare("UPDATE live_activities SET pending_sequence = CASE WHEN projection_consent = 1 THEN (SELECT projection.sequence FROM live_projections AS projection JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch WHERE projection.workspace_id = live_activities.workspace_id AND projection.window_id = live_activities.window_id) ELSE NULL END, last_sent_at = NULL, dispatch_lease = NULL, dispatching_until = NULL WHERE activity_id = ? AND workspace_id = ? AND device_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'viewer' AND revoked_at IS NULL)")
      .bind(activityId, viewer.workspace_id, viewer.device_id, viewer.device_id, viewer.workspace_id, viewer.token_hash),
  ]);
  return (results[0]?.meta.changes ?? 0) === 1 && (results[1]?.meta.changes ?? 0) === 1 ? json({ ok: true }) : problem(403, "activity_not_owned");
}
async function endActivity(env: Env, viewer: Device, activityId: string): Promise<Response> {
  if (viewer.role !== "viewer") return problem(403, "role_forbidden");
  const result = await env.DB.prepare("DELETE FROM live_activities WHERE activity_id = ? AND workspace_id = ? AND device_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND revoked_at IS NULL)").bind(activityId, viewer.workspace_id, viewer.device_id, viewer.device_id, viewer.workspace_id, viewer.token_hash).run();
  return (result.meta.changes ?? 0) === 1 ? json({ ok: true }) : problem(404, "activity_not_found");
}
function projection(value: Record<string, unknown>): Record<string, unknown> | null {
  const keys = ["sequence", "windowId", "label", "remainingBps", "displayState", "observedAt", "staleAt", "resetsAt"];
  const states = new Set(["fresh", "low", "exhausted", "stale", "resetPending", "unavailable", "unlimited", "authRequired"]);
  const timestamp = (candidate: unknown): number | null => {
    if (candidate === null) return null;
    if (typeof candidate !== "string") return Number.NaN;
    const parsed = Date.parse(candidate);
    return Number.isFinite(parsed) && new Date(parsed).toISOString() === candidate ? parsed : Number.NaN;
  };
  const observed = timestamp(value.observedAt), stale = timestamp(value.staleAt), reset = timestamp(value.resetsAt);
  if (!hasOnly(value, keys) || Object.keys(value).length !== keys.length || !Number.isSafeInteger(value.sequence) || (value.sequence as number) < 1 || !stringField(value.windowId, 80, idPattern) || !stringField(value.label, 32) || !states.has(value.displayState as string) || Number.isNaN(observed) || Number.isNaN(stale) || Number.isNaN(reset) || (observed !== null && observed > Date.now() + 120_000) || (observed !== null && stale !== null && stale < observed) || !(value.remainingBps === null || (Number.isInteger(value.remainingBps) && (value.remainingBps as number) >= 0 && (value.remainingBps as number) <= 10000))) return null;
  return JSON.stringify(value).length <= 1024 ? value : null;
}
function canonicalProjection(value: Record<string, unknown>): string {
  return JSON.stringify(Object.fromEntries(["sequence", "windowId", "label", "remainingBps", "displayState", "observedAt", "staleAt", "resetsAt"].map(key => [key, value[key]])));
}
export async function flushPending(env: Env, transport: PushTransport, workspaceId: string | null = null, windowId: string | null = null): Promise<void> {
  await flushV2(env, transport, decryptActivityToken);
  const current = now();
  const rows = await env.DB.prepare("SELECT activity.activity_id, activity.device_id, activity.window_id, activity.token_ciphertext, activity.environment, activity.ends_at, activity.last_sent_at, activity.backoff_until, activity.pending_sequence, projection.projection_json FROM live_activities AS activity JOIN live_projections AS projection ON projection.workspace_id = activity.workspace_id AND projection.window_id = activity.window_id AND projection.sequence = activity.pending_sequence JOIN workspaces AS workspace ON workspace.workspace_id = activity.workspace_id AND workspace.source_epoch = projection.source_epoch WHERE activity.pending_sequence IS NOT NULL AND activity.projection_consent = 1 AND activity.disabled_at IS NULL AND activity.ends_at > ? AND (activity.backoff_until IS NULL OR activity.backoff_until <= ?) AND (activity.dispatching_until IS NULL OR activity.dispatching_until <= ?) AND (activity.last_sent_at IS NULL OR activity.last_sent_at <= ?) AND (? IS NULL OR activity.workspace_id = ?) AND (? IS NULL OR activity.window_id = ?) AND EXISTS (SELECT 1 FROM devices WHERE device_id = activity.device_id AND workspace_id = activity.workspace_id AND role = 'viewer' AND revoked_at IS NULL) ORDER BY activity.updated_at ASC LIMIT 32")
    .bind(current, current, current, new Date(Date.now() - activityCooldownMs).toISOString(), workspaceId, workspaceId, windowId, windowId).run<QueuedActivity>();
  for (const activity of rows.results) {
    const lease = randomId(), leaseUntil = new Date(Date.now() + 60_000).toISOString();
    const claimed = await env.DB.prepare("UPDATE live_activities SET dispatch_lease = ?, dispatching_until = ? WHERE activity_id = ? AND pending_sequence = ? AND projection_consent = 1 AND disabled_at IS NULL AND ends_at > ? AND (backoff_until IS NULL OR backoff_until <= ?) AND (dispatching_until IS NULL OR dispatching_until <= ?) AND (last_sent_at IS NULL OR last_sent_at <= ?) AND EXISTS (SELECT 1 FROM devices WHERE device_id = live_activities.device_id AND workspace_id = live_activities.workspace_id AND role = 'viewer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM live_projections AS projection JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch WHERE projection.workspace_id = live_activities.workspace_id AND projection.window_id = live_activities.window_id AND projection.sequence = live_activities.pending_sequence)")
      .bind(lease, leaseUntil, activity.activity_id, activity.pending_sequence, now(), now(), now(), new Date(Date.now() - activityCooldownMs).toISOString()).run();
    if ((claimed.meta.changes ?? 0) !== 1) continue;
    const token = await decryptActivityToken(env, activity.token_ciphertext);
    if (!token) {
      await env.DB.prepare("UPDATE live_activities SET disabled_at = ?, pending_sequence = NULL, dispatch_lease = NULL, dispatching_until = NULL WHERE activity_id = ? AND dispatch_lease = ?").bind(now(), activity.activity_id, lease).run();
      continue;
    }
    let disposition: Awaited<ReturnType<typeof dispatchPush>>;
    try {
      const data = JSON.parse(activity.projection_json) as Record<string, unknown>;
      disposition = await dispatchPush(transport, token, activity.environment, buildActivityPayload(data, activity.ends_at, Math.floor(Date.now() / 1000)));
    } catch { disposition = { kind: "unavailable" }; }
    if (disposition.kind === "sent") await env.DB.prepare("UPDATE live_activities SET last_sent_at = ?, pending_sequence = CASE WHEN pending_sequence = ? THEN NULL ELSE pending_sequence END, dispatch_lease = NULL, dispatching_until = NULL WHERE activity_id = ? AND dispatch_lease = ?").bind(now(), activity.pending_sequence, activity.activity_id, lease).run();
    else if (disposition.kind === "disabled") await env.DB.prepare("UPDATE live_activities SET disabled_at = ?, pending_sequence = NULL, dispatch_lease = NULL, dispatching_until = NULL WHERE activity_id = ? AND dispatch_lease = ?").bind(now(), activity.activity_id, lease).run();
    else await env.DB.prepare("UPDATE live_activities SET backoff_until = ?, updated_at = ?, dispatch_lease = NULL, dispatching_until = NULL WHERE activity_id = ? AND dispatch_lease = ?").bind(new Date(Date.now() + 60_000).toISOString(), now(), activity.activity_id, lease).run();
  }
}
export async function reconcilePending(env: Env): Promise<void> {
  await env.DB.prepare("UPDATE live_activities SET pending_sequence = (SELECT projection.sequence FROM live_projections AS projection JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch WHERE projection.workspace_id = live_activities.workspace_id AND projection.window_id = live_activities.window_id) WHERE projection_consent = 1 AND disabled_at IS NULL AND ends_at > ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = live_activities.device_id AND workspace_id = live_activities.workspace_id AND role = 'viewer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM live_projections AS projection JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch WHERE projection.workspace_id = live_activities.workspace_id AND projection.window_id = live_activities.window_id AND (live_activities.last_sent_at IS NULL OR live_activities.last_sent_at < projection.updated_at) AND (live_activities.pending_sequence IS NULL OR live_activities.pending_sequence < projection.sequence))")
    .bind(now()).run();
}
export async function putProjection(request: Request, env: Env, writer: Device, transport: PushTransport): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden"); const body = await readJson(request); if (body === "too_large") return problem(413, "payload_too_large"); const data = body && projection(body); if (!data) return problem(400, "invalid_projection");
  const source = await workspace(env, writer.workspace_id); if (!source) return problem(401, "invalid_credential");
  const serialized = canonicalProjection(data);
  const existing = await env.DB.prepare("SELECT sequence, projection_json FROM live_projections WHERE workspace_id = ? AND window_id = ? AND source_epoch = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'writer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?)").bind(writer.workspace_id, data.windowId, source.source_epoch, writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, source.source_epoch).first<{ sequence: number; projection_json: string }>();
  if (existing && existing.sequence > (data.sequence as number)) return problem(409, "projection_sequence_conflict");
  if (existing && existing.sequence === data.sequence) {
    try { if (canonicalProjection(JSON.parse(existing.projection_json) as Record<string, unknown>) !== serialized) return problem(409, "projection_sequence_conflict"); }
    catch { return problem(409, "projection_sequence_conflict"); }
    await flushPending(env, transport, writer.workspace_id, data.windowId as string);
    return json({ ok: true });
  }
  const stored = await env.DB.batch([
    env.DB.prepare("INSERT INTO live_projections(workspace_id, window_id, source_epoch, sequence, projection_json, updated_at) SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'writer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?) ON CONFLICT(workspace_id,window_id) DO UPDATE SET source_epoch=excluded.source_epoch,sequence=excluded.sequence,projection_json=excluded.projection_json,updated_at=excluded.updated_at WHERE excluded.source_epoch != live_projections.source_epoch OR excluded.sequence > live_projections.sequence")
      .bind(writer.workspace_id, data.windowId, source.source_epoch, data.sequence, serialized, now(), writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, source.source_epoch),
    env.DB.prepare("UPDATE live_activities SET pending_sequence = ? WHERE changes() = 1 AND workspace_id = ? AND window_id = ? AND projection_consent = 1 AND disabled_at IS NULL AND ends_at > ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = live_activities.device_id AND workspace_id = live_activities.workspace_id AND role = 'viewer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM live_projections WHERE workspace_id = ? AND window_id = ? AND source_epoch = ? AND sequence = ? AND projection_json = ?)")
      .bind(data.sequence, writer.workspace_id, data.windowId, now(), writer.workspace_id, data.windowId, source.source_epoch, data.sequence, serialized),
  ]);
  if ((stored[0]?.meta.changes ?? 0) !== 1) {
    // A concurrent identical PUT may win the compare-and-set after our first
    // read. Recheck the committed value before calling this retry a conflict.
    const concurrent = await env.DB.prepare("SELECT sequence, projection_json FROM live_projections WHERE workspace_id = ? AND window_id = ? AND source_epoch = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'writer' AND revoked_at IS NULL) AND EXISTS (SELECT 1 FROM workspaces WHERE workspace_id = ? AND source_epoch = ?)")
      .bind(writer.workspace_id, data.windowId, source.source_epoch, writer.device_id, writer.workspace_id, writer.token_hash, writer.workspace_id, source.source_epoch).first<{ sequence: number; projection_json: string }>();
    if (!concurrent || concurrent.sequence !== data.sequence) return problem(409, "projection_not_admitted");
    try { if (canonicalProjection(JSON.parse(concurrent.projection_json) as Record<string, unknown>) !== serialized) return problem(409, "projection_not_admitted"); }
    catch { return problem(409, "projection_not_admitted"); }
  }
  await flushPending(env, transport, writer.workspace_id, data.windowId as string);
  return json({ ok: true });
}

const alertSeverities = new Set(["info", "warning", "critical"]);
const alertRelayCooldownMs = 60_000;

export async function putAlertToken(request: Request, env: Env, viewer: Device): Promise<Response> {
  if (viewer.role !== "viewer") return problem(403, "role_forbidden");
  const body = await readJson(request); if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["token", "environment"]) || !stringField(body.token, 512) || (body.environment !== "sandbox" && body.environment !== "production")) return problem(400, "invalid_request");
  if (!await env.DB.prepare("SELECT 1 FROM devices WHERE device_id = ? AND workspace_id = ? AND token_hash = ? AND role = 'viewer' AND revoked_at IS NULL").bind(viewer.device_id, viewer.workspace_id, viewer.token_hash).first()) return problem(403, "role_forbidden");
  const encrypted = await encryptDelivery(env, { token: body.token }); if (!encrypted) return problem(503, "delivery_secret_unavailable");
  const result = await env.DB.prepare("INSERT INTO alert_push_tokens(device_id, workspace_id, token_ciphertext, environment, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(device_id, workspace_id) DO UPDATE SET token_ciphertext=excluded.token_ciphertext, environment=excluded.environment, updated_at=excluded.updated_at")
    .bind(viewer.device_id, viewer.workspace_id, encrypted, body.environment, now(), now()).run();
  return (result.meta.changes ?? 0) === 1 ? json({ ok: true }) : problem(500, "storage_unavailable");
}

export async function deleteAlertToken(env: Env, viewer: Device): Promise<Response> {
  if (viewer.role !== "viewer") return problem(403, "role_forbidden");
  await env.DB.prepare("DELETE FROM alert_push_tokens WHERE device_id = ? AND workspace_id = ?").bind(viewer.device_id, viewer.workspace_id).run();
  return json({ ok: true });
}

export async function putAlertSettings(request: Request, env: Env, writer: Device): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request); if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["phoneAlertsEnabled"]) || typeof body.phoneAlertsEnabled !== "boolean") return problem(400, "invalid_request");
  const result = await env.DB.prepare("INSERT INTO alert_settings(workspace_id, phone_alerts_enabled, updated_at) VALUES(?, ?, ?) ON CONFLICT(workspace_id) DO UPDATE SET phone_alerts_enabled=excluded.phone_alerts_enabled, updated_at=excluded.updated_at")
    .bind(writer.workspace_id, body.phoneAlertsEnabled ? 1 : 0, now()).run();
  return (result.meta.changes ?? 0) === 1 ? json({ ok: true }) : problem(500, "storage_unavailable");
}

export async function postAlertPush(request: Request, env: Env, writer: Device, transport: PushTransport): Promise<Response> {
  if (writer.role !== "writer") return problem(403, "role_forbidden");
  const body = await readJson(request); if (body === "too_large") return problem(413, "payload_too_large");
  if (!body || !hasOnly(body, ["alertId", "title", "body", "severity"]) || !stringField(body.alertId, 80, idPattern) || !stringField(body.title, 120) || !stringField(body.body, 400) || !alertSeverities.has(body.severity as string)) return problem(400, "invalid_request");
  const settings = await env.DB.prepare("SELECT phone_alerts_enabled FROM alert_settings WHERE workspace_id = ?").bind(writer.workspace_id).first<{ phone_alerts_enabled: number }>();
  if (!settings || settings.phone_alerts_enabled !== 1) return problem(403, "alert_relay_disabled");
  // Idempotent per alertId: the same rule firing twice with the same id relays
  // once, so Mac retries never spam the phone. Cooldown dedupes distinct ids.
  const log = await env.DB.prepare("INSERT INTO alert_push_log(alert_id, workspace_id, sent_at) VALUES(?, ?, ?) ON CONFLICT(alert_id, workspace_id) DO NOTHING").bind(body.alertId, writer.workspace_id, now()).run();
  if ((log.meta.changes ?? 0) !== 1) return json({ ok: true, deduplicated: true });
  const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_push_log WHERE workspace_id = ? AND sent_at > ?").bind(writer.workspace_id, new Date(Date.now() - alertRelayCooldownMs).toISOString()).first<{ n: number }>();
  if (!recent || recent.n > 1) {
    await env.DB.prepare("DELETE FROM alert_push_log WHERE alert_id = ? AND workspace_id = ?").bind(body.alertId, writer.workspace_id).run();
    return problem(429, "rate_limited");
  }
  const rows = await env.DB.prepare("SELECT token.device_id, token.token_ciphertext, token.environment FROM alert_push_tokens AS token WHERE token.workspace_id = ? AND EXISTS (SELECT 1 FROM devices WHERE device_id = token.device_id AND workspace_id = token.workspace_id AND role = 'viewer' AND revoked_at IS NULL)").bind(writer.workspace_id).all<{ device_id: string; token_ciphertext: string; environment: string }>();
  let accepted = 0, failed = 0;
  for (const row of rows.results) {
    const token = await decryptActivityToken(env, row.token_ciphertext);
    if (!token) { await env.DB.prepare("DELETE FROM alert_push_tokens WHERE device_id = ? AND workspace_id = ?").bind(row.device_id, writer.workspace_id).run(); failed += 1; continue; }
    const payload = { aps: { alert: { title: body.title, body: body.body }, sound: "default" } };
    let disposition: Awaited<ReturnType<typeof dispatchPush>>;
    try { disposition = await dispatchPush(transport, token, row.environment as "sandbox" | "production", payload, "alert" as const); }
    catch { disposition = { kind: "unavailable" }; }
    if (disposition.kind === "sent" || disposition.kind === "unavailable") accepted += 1;
    else if (disposition.kind === "disabled") { await env.DB.prepare("DELETE FROM alert_push_tokens WHERE device_id = ? AND workspace_id = ?").bind(row.device_id, writer.workspace_id).run(); failed += 1; }
    else failed += 1;
  }
  return json({ ok: true, accepted, failed });
}

async function pruneAlertLog(env: Env): Promise<void> {
  await env.DB.prepare("DELETE FROM alert_push_log WHERE sent_at <= ?").bind(new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()).run();
}

export default {
  async scheduled(_event: unknown, env: Env): Promise<void> { await reconcilePending(env); await pruneAlertLog(env); await flushPending(env, new ApnsTransport(env)); },
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url); const route = routePath(url.pathname);
    if (request.method === "GET" && url.pathname === "/v1/capabilities") return json({ schemaVersions: ["1.0.0"], ...(await v2Available(env) ? { activityContentVersions: [1, 2] } : {}), pushMode: env.APNS_TEAM_ID && env.APNS_KEY_ID && env.APNS_PRIVATE_KEY && env.APNS_TOPIC ? "own_team" : "disabled", maxEnvelopeBytes: 262144, serverTime: now() });
    if (url.pathname === "/mcp" && request.method !== "POST") return problem(405, "method_not_allowed");
    const scope = isV2Route(url.pathname) ? `${request.method}:/v2/activities` : rateScope(request.method, url.pathname, route);
    if (!scope) return problem(404, "unsupported_route");
    if (!(await allowed(request, env, scope))) return problem(429, "rate_limited");
    if (isV2Route(url.pathname)) { const device = await authenticateDevice(request, env); return device ? handleV2(request, env, device, { json, problem, readJson, encryptStored }) : problem(401, "invalid_credential"); }
    if (url.pathname === "/mcp") return handleMCP(request, env);
    if (url.pathname === "/v1/mcp-access" || url.pathname === "/v1/mcp-snapshot") {
      const device = await authenticateDevice(request, env);
      return device ? manageMCP(request, env, device) : problem(401, "invalid_credential");
    }
    if (isShareRoute(url.pathname)) return handleShare(request, env, authenticateDevice);
    await expirePairings(env);
    await cleanupSnapshots(env);
    if (request.method === "POST" && url.pathname === "/v1/bootstrap") return bootstrap(request, env);
    if (request.method === "POST" && url.pathname === "/v1/pairings") {
      const device = await authenticateDevice(request, env); return device ? createPairing(request, env, device) : problem(401, "invalid_credential");
    }
    if (route.pairingId && request.method === "POST" && route.action === "claim") return claimPairing(request, env, route.pairingId);
    if (route.pairingId && request.method === "GET" && route.action === "result") return pairingResult(request, env, route.pairingId);
    if (route.pairingId && request.method === "POST" && route.action === "ack") return acknowledgePairing(request, env, route.pairingId);
    if (route.pairingId && request.method === "GET" && !route.action) {
      const device = await authenticateDevice(request, env); return device ? inspectPairing(env, device, route.pairingId) : problem(401, "invalid_credential");
    }
    if (route.pairingId && request.method === "POST" && route.action === "approve") {
      const device = await authenticateDevice(request, env); return device ? approvePairing(request, env, device, route.pairingId) : problem(401, "invalid_credential");
    }
    if (url.pathname === "/v1/usage" && (request.method === "GET" || request.method === "PUT")) {
      const device = await authenticateDevice(request, env);
      if (!device) return problem(401, "invalid_credential");
      await cleanupUsage(env);
      return request.method === "GET" ? getUsage(request, env, device) : putUsage(request, env, device);
    }
    if (url.pathname === "/v1/snapshot" && (request.method === "GET" || request.method === "PUT")) {
      const device = await authenticateDevice(request, env);
      if (!device) return problem(401, "invalid_credential");
      return request.method === "GET" ? getSnapshot(request, env, device) : putSnapshot(request, env, device);
    }
    if (request.method === "POST" && url.pathname === "/v1/source-key-rotations") {
      const device = await authenticateDevice(request, env); return device ? rotateSourceKey(request, env, device) : problem(401, "invalid_credential");
    }
    if (request.method === "GET" && url.pathname === "/v1/device-key-wrap") {
      const device = await authenticateDevice(request, env); return device ? getOwnDeviceKeyWrap(env, device) : problem(401, "invalid_credential");
    }
    if (route.activityId && request.method === "PUT") { const device = await authenticateDevice(request, env); return device ? registerActivity(request, env, device, route.activityId) : problem(401, "invalid_credential"); }
    if (route.activityId && request.method === "DELETE") { const device = await authenticateDevice(request, env); return device ? endActivity(env, device, route.activityId) : problem(401, "invalid_credential"); }
    if (request.method === "PUT" && url.pathname === "/v1/live-projections") { const device = await authenticateDevice(request, env); return device ? putProjection(request, env, device, new ApnsTransport(env)) : problem(401, "invalid_credential"); }
    if (url.pathname === "/v1/alert-token" && (request.method === "PUT" || request.method === "DELETE")) {
      const device = await authenticateDevice(request, env); if (!device) return problem(401, "invalid_credential");
      return request.method === "PUT" ? putAlertToken(request, env, device) : deleteAlertToken(env, device);
    }
    if (request.method === "PUT" && url.pathname === "/v1/alert-settings") { const device = await authenticateDevice(request, env); return device ? putAlertSettings(request, env, device) : problem(401, "invalid_credential"); }
    if (request.method === "POST" && url.pathname === "/v1/alert-push") { const device = await authenticateDevice(request, env); return device ? postAlertPush(request, env, device, new ApnsTransport(env)) : problem(401, "invalid_credential"); }
    if (request.method === "GET" && url.pathname === "/v1/devices") {
      const device = await authenticateDevice(request, env); return device ? listDevices(env, device) : problem(401, "invalid_credential");
    }
    if (route.deviceId && request.method === "DELETE") {
      const device = await authenticateDevice(request, env); return device ? revokeDevice(env, device, route.deviceId) : problem(401, "invalid_credential");
    }
    return problem(404, "unsupported_route");
  },
};
