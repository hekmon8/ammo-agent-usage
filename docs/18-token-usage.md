# Recorded token usage and private receipts

This feature is separate from quota windows and billing. It counts readable local
Claude Code and Codex usage records once per collecting Mac. It never multiplies
usage by provider/account connections, derives tokens from remaining percentages,
or sums snapshots from different Macs.

## Enable and use

Open **Usage** in the Mac sidebar and explicitly enable local-log analysis. This
consent is separate from connecting a quota provider. Standard sources are
`~/.claude/projects` (also `~/.config/claude/projects`) and
`~/.codex/sessions` / `~/.codex/archived_sessions`. Launch-time
`CLAUDE_CONFIG_DIR` and `CODEX_HOME` overrides are respected. Symlinked files or
roots and files owned by a different OS user are skipped. No agent process,
credential file, account API, price API or paid call is used.

Analysis runs off the UI thread every five minutes while enabled and on manual
refresh. A scan replaces the retained daily aggregates; polling a cumulative log
never adds the previous scan again. The last 400 local calendar days are retained.
Changing the collecting timezone rescans the local logs. iPhone displays the
collector's timezone, because daily aggregates cannot be safely rebinned there.

Day, Monday–Sunday natural week, calendar month and trailing seven calendar days
are distinct choices. Boundaries use Gregorian calendar arithmetic in the chosen
timezone, including daylight-saving transitions. The current period is partial.

## Counting contract

- Claude Code: assistant `message.usage` only; deduplicate globally by the provider
  message ID, even when `requestId` is absent. Streaming/final representations
  replace per-category counters, and retain the earliest observation date. Input,
  cache-read, cache-creation and output are disjoint Anthropic fields.
- Codex: `event_msg/token_count/info.total_token_usage` only, after `session_meta`.
  Positive differences of cumulative counters count once; unchanged notifications
  do not add `last_token_usage`. Cached input is included in `input_tokens` and
  is subtracted to obtain non-cached input. Reasoning is included in output, so it
  is not added again. Repeated/overlapping session files are reconciled globally
  by canonical session and cumulative counter, preserving the earliest timestamp.
  Deltas follow a monotonic high-water mark across all files for that session. Forked rollouts are conservatively excluded and marked incomplete:
  Codex can re-stamp inherited history with child-time timestamps and copy ancestor
  metadata, so cumulative counters cannot safely distinguish new child work yet.
- Counter decreases, malformed rows, inconsistent totals, unknown nonzero Codex
  cache-write semantics, missing stable identities and scan limits are marked
  incomplete. They do not manufacture zero or a guessed token count. Compaction
  counter resets retain the preceding high-water mark; only amounts above that
  mark can be attributed safely. Reset/rewind sessions may therefore undercount.
- No model attribution is presented in this first slice: cumulative Codex counters
  spanning model switches cannot safely establish per-model attribution.

The native parser is intentionally independent of ccusage (no runtime download,
package installation, pricing lookup or copied implementation). Schema references:
[Codex protocol](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs),
[Anthropic prompt-caching usage](https://docs.claude.com/en/docs/build-with-claude/prompt-caching),
[ccusage duplicate-event report](https://github.com/ccusage/ccusage/issues/884).

## Coverage and privacy

All totals are **recorded tokens / partial coverage**, not complete account usage
or billable tokens. Missing/unreadable sources are unavailable, not zero. The
source panel includes scan and latest-event timestamps. A successfully readable
source with no records in the chosen period can show zero recorded tokens; a
missing source, all-unavailable range, or range outside retention shows unknown.
Local log deletion, unsupported schemas, tools on another device and hosted
sessions are outside coverage. Enumeration is bounded to 50,000 entries, files to 10,000 and reads to 512 MiB per source,
lines to 2 MiB, and ephemeral distinct usage records to 200,000 per scan. Skipped
content is reported as partial coverage. No transcript/project text, request IDs
or session IDs are persisted in aggregate output.

Only aggregate day/agent/categories and coverage timestamps are saved locally in
an app-owned mode-0600 file. Deduplication identifiers exist only during a scan.
Disabling analysis stops scanning and replaces the enabled usage snapshot with
empty disabled-source metadata. While disabled, a running Mac renews this empty
observation once per day (without reading logs), because Worker ciphertext expires
seven days after receipt. Restarting after a long suspension also renews it. Local
save failures and offline uploads are retried; sequence and ciphertext remain
stable between renewals. An offline phone may retain its last authenticated
observation until its next successful pull; the timestamp and cached state stay
visible. If the Mac itself is offline or stopped beyond remote retention, the
phone cannot learn the changed consent until the Mac returns and uploads again.

## Encrypted Worker compatibility

Deploy migration `0014_token_usage.sql` and the updated Worker to enable phone
usage sync. Deployment is a separate maintainer action; this PR never deploys.
The new `/v1/usage` sidecar uses the existing paired writer/viewer authorization
and encryption keys, with domain-separated signatures/AAD (`QI-USAGE|1`). It is
independent of the strict `/v1/snapshot` quota protocol, its sequence/cache, and
remaining-balance history. Old clients keep their v1 quota payloads unchanged.
An old Worker returns unsupported for usage while quota sync continues.

The Worker retains one encrypted replacement aggregate from its authorized Mac,
not a ledger or cross-device total. Plaintext is bounded to 128 KiB. The iPhone
checks signature, source/epoch/key pinning and monotonic sequence before caching.
iCloud-only sync does not carry usage in this first slice; the phone explains the
Worker requirement rather than showing sample numbers.

## Receipt export

Mac and iPhone preview a thermal-paper receipt from the same selected summary,
then save a PNG or open the system share sheet. The image contains only period,
timezone, source names, recorded category totals, coverage and as-of time. It
contains no account IDs, aliases, project names, conversations, credentials or
source-device identifiers. iPhone requests Photos add-only access only after a
Save Image tap. Export failure/cancellation leaves the preview available.

## Verification

Synthetic Swift tests cover categories, Claude streaming/copies, Codex repeated
counters/resets/forks, malformed rows, replacement scans, privacy, timezone and
DST periods, strict schema and unknown states. Worker tests cover authorization,
cross-protocol replay, retries, concurrency, expiry, payload bounds and old-v1
compatibility. Native build/device/visual checks require Apple tooling; a Linux
cloud check does not claim to have rendered either app or used a real account.
