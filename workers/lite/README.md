# lite

`contracts/openapi.json` owns the HTTP boundary. Authorization, pairing, bootstrap replay, snapshots, rotations, and consented Live Activity registration/projection use D1 predicates and encrypted stored delivery values.

Local synthetic setup (no production credentials): run `npm ci` in `workers/lite` to install its pinned dependencies, set `BOOTSTRAP_ENABLED=true`, `BOOTSTRAP_SECRET` and a base64url 32-byte `DELIVERY_ENCRYPTION_KEY`, then run `npm run migrate:local` and Wrangler locally. The migration stores hashes of device, pairing and claim tokens, never raw tokens. Temporary pairing delivery is AES-GCM encrypted with the Worker secret and is deleted on acknowledgement.

Bootstrap is multi-tenant since `0009_bootstrap_tenants`: every valid bootstrap token provisions exactly one independent workspace, and all data access stays workspace-scoped. A hosted deployment serving multiple users sets `BOOTSTRAP_SECRETS` to a JSON array of tokens (each user gets their own token; up to 128 listed tokens — the legacy `BOOTSTRAP_SECRET` does not consume a slot). `BOOTSTRAP_SECRET` stays a single-workspace credential even across rotation: every successful legacy bootstrap records the `bootstrap_state` singleton row, which blocks any legacy secret from provisioning a second workspace, while `BOOTSTRAP_SECRETS` tokens are unaffected. Applying migration `0009` is required before using per-tenant tokens; no production migration or deployment is automated.

The APNs transport uses a dedicated activity-token decoder and the native payload builder (epoch-second content timestamps, stale date bounded by the session deadline). `npm run test:push` exercises registration, encrypted-token recovery, transport dispatch, and failure classification with synthetic data; `npm run test:http` runs the role/pairing/revocation boundary against temporary local D1.

Remote monitoring is opt-in on both Mac and iPhone. The Mac switch discloses all percentage-window summaries to the self-hosted service, including windows without an active phone session; full snapshots remain encrypted. The service pushes only to matching, consented, unexpired activities. Client registration or projection acceptance is not a delivery receipt. Real background delivery additionally requires deploying this Worker revision, matching APNs team/topic/environment and a push-enabled signed iOS build, then verifying on a device. No production deployment or APNs configuration is performed by the local tests.

## One-account quota shares

Apply migration `0010_quota_shares.sql` before deploying these routes. Sharing is separate from pairing and the encrypted full snapshot: the writer explicitly consents to upload a **plaintext, minimal quota projection** for one exact provider-account connection. It contains only the selected quota windows; it must never include account IDs, provider credentials, history, or a snapshot key. The Worker stores the private account ID only for the writer's own share listing and authorization workflow; recipient responses expose provider ID, chosen label, timestamp, and validated quota windows, not account ID. A recipient needs no existing workspace or full-sync pairing.

`POST /v1/shares` (writer token; `{connectionId,providerId,accountId,label,inviteSecretHash}`) creates a ten-minute single-claim invite and returns `{shareId,expiresAt}`. The client shares `quotaisland://share#<base64url JSON {version:1,endpoint,shareId,secret}>`, with an HTTPS Worker endpoint; only SHA-256 of the random invite secret is sent to the server. `GET /v1/shares` lists the writer's own records, including `{shareId,connectionId,providerId,accountId,label,state,recipientName,claimId,verificationCode,expiresAt}`. Pending unclaimed invites become `expired` at ten minutes. A recipient claims with `POST /v1/shares/{shareId}/claim`, bearer invite secret and `{recipientName}`; the response is `{claimId,claimToken,verificationCode}`. Claim is atomic and exclusive. A timely claim remains actionable for at most 24 hours; after that approval is rejected and a new invite is needed.

The writer compares the six-digit code shown on both devices and approves with `POST /v1/shares/{shareId}/approve` and `{claimId}`. The recipient polls `GET /v1/shares/{shareId}/result` using the claim token: `{state:\"claimed\"}` until approval, then `{state:\"approved\",viewerToken}`. The token is encrypted at rest for delivery and its SHA-256 hash authorizes reads; the plaintext is available to the claimant for **24 hours after approval**, then the result endpoint returns `410 share_delivery_expired`. The recipient must save it securely before then. The viewer grant itself has no deadline and remains valid until revocation.

`PUT /v1/shares/{shareId}/projection` (writer token) accepts `{capturedAt,windows}` only after approval; max 80 windows, 96 KiB body, exact allowed fields per window: `{quotaKey,unit,currency,availability,remainingBps,amount,limit,quality,fetchOutcome,observedAt,staleAt,resetsAt}`. `GET /v1/shares/{shareId}/projection` requires that share's viewer token and responds `{shareId,providerId,label,capturedAt,windows}`. Publishing newer projections replaces older ones; stale captured timestamps are rejected. `DELETE /v1/shares/{shareId}` (writer token) idempotently revokes even pending or expired shares, clears delivery and projection data, and immediately denies claim, result, and viewer reads. The writer must revoke remote grants before disabling/deleting/replacing a shared connection; an offline failure must not be represented as a completed revoke.

Local synthetic HTTP coverage is in `test/share-http.mjs` (local D1 migration and Wrangler, no hosted credentials).

## APNs 配置

远程监看的推送由 Worker 直接调用 APNs（token 认证，ES256 JWT）。只有当以下四个 Secrets 全部配置时，`GET /v1/capabilities` 才会返回 `pushMode: "own_team"`，iPhone 的「允许后台监看更新」开关才可用；否则返回 `disabled`：

| Secret | 值 |
|---|---|
| `APNS_TEAM_ID` | Apple Developer Team ID（10 位，如 App 签名团队） |
| `APNS_KEY_ID` | APNs Auth Key 的 Key ID（10 位，即 .p8 文件名 `AuthKey_<KEYID>.p8` 中的部分） |
| `APNS_PRIVATE_KEY` | .p8 文件的完整 PEM 内容（含 BEGIN/END 行） |
| `APNS_TOPIC` | iOS App 的 Bundle ID（Worker 自动追加 `.push-type.liveactivity`） |

配置步骤（需已 `wrangler login` 或导出 `CLOUDFLARE_API_TOKEN`，或直接运行 `scripts/configure-apns.sh`）：

```sh
# Use your own account, Worker config, topic and endpoint. Validate first.
export CLOUDFLARE_ACCOUNT_ID=<your-account-id>
# Also supply CLOUDFLARE_API_TOKEN privately; it is used to verify endpoint ownership.
export APNS_TEAM_ID=<your-team-id>
scripts/configure-apns.sh /absolute/AuthKey_<KEYID>.p8 org.example.ammo /absolute/wrangler.production.jsonc https://your-worker.workers.dev --dry-run
# Remove --dry-run only when ready to apply one bulk secret update.
```

创建 .p8：developer.apple.com → Certificates, Identifiers & Profiles → Keys → 新建 Key 并勾选 **Apple Push Notifications service (APNs)**，下载 .p8（只能下载一次）并记录 Key ID。Token 认证的 Key 同时适用于 sandbox 与 production；每次注册携带的 environment 决定发往哪个 APNs 端点，因此 Debug（sandbox）与 TestFlight/Release（production）构建可用同一把 Key。

配置后验证：`curl https://<your-worker>/v1/capabilities` 应返回 `"pushMode":"own_team"`。真正的端到端验证仍需真机：手机与 Mac 配对、开启后台监看、开始一次监看并在 App 退到后台后观察灵动岛更新（APNs 2xx 不等于已在设备展示）。

注册窗口语义：服务端把每次注册限制在滚动 4 小时内（`activityLifetimeMs`），并且允许同一 `activity_id` 的重注册刷新 token 并把 `ends_at` 延长到新的（仍 ≤ +4h）值。App 端因此会把长会话钳制注册为前 4 小时覆盖，并在前台/后台刷新时机通过 re-register 持续延长；跨过单活动 8 小时平台上限的连续显示由 App 的续期链（新 activity）负责，Worker 不构造 `start` 事件。


## Self-hosting without the author's infrastructure

The committed config contains an all-zero placeholder database ID suitable for
local tests. For deployment, copy it to ignored `wrangler.production.jsonc`, choose
your own Worker name, run `wrangler d1 create <your-name>` in your account, and set
the returned ID. Apply migrations to a separate staging database before production.
Always pass `--config wrangler.production.jsonc` explicitly for remote commands.
No account ID, signing key, bootstrap secret or live database binding is shipped.

Apply migrations `0011_pending_live_push.sql` and `0012_apns_provider_token_cache.sql` before deploying the retry-capable
Worker. Its every-minute cron retries pending APNs projections until sent,
disabled or expired; it never extends an activity beyond its registration deadline.
A response accepting a projection does not certify physical device delivery.
Same-sequence projections must match the already accepted content exactly.
Unknown routes do not create rate-limit rows; parameterized routes share a fixed
limit bucket rather than receiving a new bucket per arbitrary ID.

Keep APNs key files and the previous full secret set in private recoverable storage.
The configuration script validates all inputs and binds the endpoint to the configured
Worker/account using the Cloudflare API, then submits one `secret bulk` request,
then verifies secret names and capabilities. It does not retrieve secret values or
prove APNs delivery. If a service-side update fails, inspect the deployment before
retrying and restore the complete prior set if necessary.

## Encrypted token usage (optional sidecar)

Apply `0014_token_usage.sql` before using `PUT/GET /v1/usage`. This is a new,
independent route; `/v1/snapshot`, strict quota schema v1 and its 128 KiB plaintext
limit are unchanged. The sidecar reuses paired writer/viewer credentials and the
workspace-pinned single Mac. AES-GCM AAD and Ed25519 use `QI-USAGE|1|` rather than
`QI|1|`, preventing cross-route replay. Its plaintext aggregate is at most 128 KiB;
the Worker enforces this via ciphertext length and a 256 KiB JSON envelope cap.

The Worker stores one encrypted cumulative aggregate per workspace, never raw
messages, local file paths, project/request identifiers, or a token-event ledger.
A newer sequence replaces the prior aggregate, rather than adding to it. An
identical retry of the latest sequence returns its original receipt without
refreshing the seven-day ciphertext expiry. Lower sequences and conflicting
same-sequence writes are rejected, including after ciphertext is purged: a small
source/sequence/hash watermark remains. Source rotation starts an independent
sequence in the newly pinned epoch. Revoked viewers cannot receive a 304.

Older Workers return 404; clients keep quota sync independent and preserve any
last-good, timestamped usage cache. Usage is not sent through plaintext quota
sharing, external MCP projections, APNs, or CloudKit in this MVP.
Run `npm run test:http` for synthetic localhost usage/auth/replay/size coverage.
`npm run test:usage` runs the same assertions against the actual Worker handler
and real in-memory SQLite for restricted containers without interface enumeration.
