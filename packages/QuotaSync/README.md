# QuotaSync

P2 implements strict AES-GCM/Ed25519 envelopes, RFC 9180 HPKE key wraps, pinned-source verification, encrypted cache isolation, durable identical retry, HTTPS-only clients and Keychain-backed pairing/bootstrap/rotation recovery. `contracts/` owns the wire boundary. Device revocation intent and the exact randomized rotation request are stored atomically before network mutations; revocation retries precede rotation.

Tests use synthetic keys and local HTTP Worker fixtures; no production key material is bundled. Viewer source-key changes require explicit fingerprint confirmation. Remote APNs projection and registration are implemented; real delivery requires a configured Worker and a signed physical-device check.

## Optional transports and external reads

Mac and phone now independently opt into Cloudflare and/or private CloudKit sync. CloudKit stores only the validated snapshot in an encrypted field; its local cache is encrypted and bound to the currently verified CloudKit account. The phone chooses the latest whole observation, preferring CF on a timestamp tie. CF remote Activities are ended locally before switching to iCloud content, so a failed unregister cannot overwrite it later.

External HTTP MCP uses a separate explicit disclosure, redacted projection and 90-day read-only bearer. Provider credentials, account names and history remain excluded. See [setup, compatibility, signing and verification boundaries](../../PRIVACY.md). The original envelope and pairing contracts are unchanged.

Worker switching persists target credentials before retiring old grants. Failed revocation remains pending. Explicitly continuing with an unavailable old service retains its credentials for later revocation and warns that old access may still exist. A second switch is blocked until that retained task is resolved.

## Token usage sidecar

`UsageEnvelopeCodec` authenticates usage under `QI-USAGE|1|` using the existing
paired key and pinned source. `SyncWriter.uploadUsage` owns separate pending bytes,
receipt and serial task, so a missing route or usage failure never gates quota
upload. Its `Bool` result is false for an older Worker's 404/405 response.
`UsageSnapshotClient` and `VerifiedUsageCache` use the same credentials and trust,
with an independent encrypted cache and ETag. Invalid/replayed responses retain
the last authenticated observation; a cache hit does not change capturedAt.
The phone selects one source's whole cumulative aggregate and never sums Macs.
