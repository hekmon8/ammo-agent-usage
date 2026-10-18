# QuotaProviders

Ammo fetches provider data in process. Every integration is a
self-developed client: Codex drives a signed native app-server inside an
isolated profile, and the other providers are direct HTTP clients against
each provider's official endpoints. No third-party provider code is embedded.

## Codex

Codex uses a digest-recorded, signed native app-server with a private UUID profile. Explicit browser login and recurring reads share its HOME, CODEX_HOME and TMPDIR, and force the file credential backend. The application never copies or switches the default Codex login. Profile directories are owner-only; existing auth.json must be a private regular file. Before launch, the selected executable must be a native Mach-O binary inside an OpenAI Developer ID-signed app bundle.

## Native API clients

Each non-Codex connection stores one explicit credential in the app-owned
Keychain vault (per-instance UUID references in connection.json, verified
identity fingerprints elsewhere). `NativeProviderAPI` dispatches to one
reader per provider; all share a bounded transport that refuses redirects,
sends no cookies, and caps response size:

| Provider | Credential | Endpoints (self-developed) |
| --- | --- | --- |
| fal | Admin API key | `api.fal.ai/v1/account/billing?expand=credits` prepaid balance |
| Cloudflare | Account Billing Read token + account ID | `/client/v4/accounts/{id}/billable-usage` v1 current-period variable charges |
| Vercel | Team-scoped billing token + team ID | `/v1/billing/charges` daily JSONL usage cost, UTC calendar month |
| Replit Enterprise | Enterprise Admin API key (`rpl_`, `read:*`) | `/v1/usage?billingPeriod=current` gross usage before credits/adjustments |
| Amp | API token | `ampcode.com/api/internal` balance text parser |
| OpenRouter | Management API key (`sk-or-…`) | `/credits` balance, optional `/key` spending cap |
| GitHub Copilot | GitHub OAuth token (`token` scheme) | `copilot_internal/user` quota snapshots, `/user` identity |
| Factory / Droid | API key | `auth/me` identity, `billing/limits` windows, legacy usage fallback |
| Manus | `session_id` cookie | Connect-RPC `GetAvailableCredits` |
| z.ai / GLM | API key + region (+ optional team headers) | monitor quota limits; China console balance |
| ZCode | This Mac's active ZCode desktop login (re-read every fetch) | personal Coding Plan 5-hour / weekly reset-card inventory; separate account from GLM API keys |
| Grok | SuperGrok bearer token | CLI billing proxy credits |
| DeepSeek | API key or platform token | official balance API / platform wallet summary |
| OpenCode Go | API key, cookie for Zen balance | `zen/go/v1/usage`; billing server balance |
| Claude | This Mac's Claude Code login (Keychain `Claude Code-credentials`, re-read every fetch), or a pasted OAuth token | `api/oauth/usage` 5-hour / weekly / Opus / Sonnet windows, `api/oauth/profile` identity; no refresh |
| Antigravity | OAuth JSON (accessToken + projectId) | cloud-code `fetchAvailableModels` + `retrieveUserQuota`; no refresh, expired tokens require re-import |
| WorkBuddy | This Mac's WorkBuddy desktop login (`CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`, re-read every fetch), or a pasted access token | `billing/meter/get-user-resource` per-package credit cycles; no refresh |

Reader-level semantics: synthetic placeholders and unlimited seats never
become windows, renewal rows are dropped, prepaid balances are money windows
only (never fabricated percentages), and every account is pinned by a
self-reported identity or a one-way credential fingerprint.

## Configuration

Version 10 configuration keeps the isolated-profile Codex kind and the
credential-backed native-provider kind. Upgrade migration keeps native-provider
records from version 4 and later (their Keychain envelopes are still readable),
drops records for kinds that no longer exist, and pauses records without an
instance profile until reconnected. Draft and retired
instance references are saved before credential/profile creation or removal;
failed cleanup is retried at startup. All removal rollback paths account for
atomic rename succeeding before directory fsync throws. Paused accounts retain
their history without loading credentials. A verified identity mismatch stops
that account until reauthorization.

Rate windows preserve real duration, reset and observation times. Credits are
one shared balance, not an amount to sum across rate-limit buckets. Missing
data never becomes zero usage or unlimited allowance. Public snapshots contain
no provider credentials, account email or remote account identifiers.

Tests cover synthetic responses for every reader (field shapes mirror the live
APIs), normalization, migration including retired-kind salvage, separate
identities, cancellation, private files, and removal isolation. They do not
establish real provider authentication. See [privacy boundaries](../../PRIVACY.md) and the synthetic tests under `tests/providers`. z.ai never reads a global ZCode login to enrich an API-key account; ZCode must be connected separately and pins its active login identity. Organization and project identifiers must be provided together for a z.ai team connection.

## Platform balances and spending

See [platform billing](../../docs/17-platform-billing.md) for credential scopes,
metric boundaries, UI grouping and local alerts. Cloudflare's v1 billing endpoint
is alpha/deprecated: this adapter uses its documented monetary fields because v2
billable usage is a different contract. It excludes fixed subscriptions and may
lag by a day. Vercel excludes non-Usage charge categories; its export is delayed.
An empty export is unavailable, not a proven zero. Replit personal/Core/Pro
balances are not supported by the public Enterprise Admin API.

Replit does not return an enterprise identifier in the documented usage response.
Its account identity is therefore a one-way credential fingerprint, following the
existing credential-scoped reader pattern. Reuse a connection's key: rotating it
requires reconnecting and recreating its alert rules; adding two keys can show the
same enterprise twice. Do not sum their amounts. No credential is sent in sync.
