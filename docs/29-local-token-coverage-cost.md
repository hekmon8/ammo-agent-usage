# Local token coverage and Standard price equivalent

The local consent switch remains the only trigger for reading Codex/Claude transcript roots. No extra homes, accounts or remote account APIs are queried. The synchronized token DTO and thermal receipt are unchanged; scan diagnostics and cost estimates stay on the Mac in an aggregate-only private sidecar.

## Diagnosis and coverage

The new scanner keeps file/entry/event limits and an 8 GiB byte budget per provider. It discards oversized lines through the next newline and resumes parsing. UI coverage shows discovered/read files, bytes, budget, cache reuse and concrete numeric gap reasons. Truncated or ambiguous history remains partial.

Modern Codex request records require canonical thread ownership and a response ID. Owned fork/subagent requests count; inherited legacy history is excluded. Matching cumulative mirrors are suppressed in either file order. A legacy prefix is accepted only if it fits the first proven request's preceding cumulative baseline; unmatched later cumulative deltas remain excluded. Conflicting response identities are permanently excluded for that scan, including later matching replays; their session's legacy cumulative scope is also excluded because its mirror boundaries are uncertain. Counter rewinds, invalid numeric fields and uncertain ownership surface as gaps instead of invented attribution. Legacy rows without a proven request input size cannot be priced at a guessed context tier.

At most one aggregate-only in-memory cache entry per provider survives a scan. The key hashes canonical scope, all discovered file identities/sizes/mtime/ctime, timezone, retained start day, budget and price version. No paths, model names, response IDs or transcript text are retained in the cached values. Unchanged roots reuse daily numeric results; changed files, timezone/retention changes, transient read failures and future events require scanning again. Turning off consent clears this cache and atomically replaces the local sidecar with an empty file. Disk-cleanup failures are shown and retried by the existing loop and after restart, including an orphaned sidecar; they never enable log reads or block a successfully saved disabled observation from reaching sync.

## Pricing semantics

Rates are USD per million tokens, verified against [OpenAI's official pricing](https://developers.openai.com/api/docs/pricing) and [Anthropic's official pricing](https://platform.claude.com/docs/en/about-claude/pricing) on October 7, 2026. The frozen version is displayed with source links. This is a **Standard API directory-price equivalent**, not a subscription charge, actual processing-mode price, provider invoice or savings figure. Historical tokens use this stated price version rather than a claim about historical billing.

Only exact supported model identifiers are priced. Unknown or ambiguous identifiers preserve token counts as unpriced; they never become zero or inherit another model's price. Duplicate legacy counters with conflicting model/request evidence remain unpriced after later matching replays. Codex inclusive input is split into non-cached input, cache reads and cache writes; reasoning is already within output and is not added again. OpenAI's long-context multipliers apply only when that request's input is proven above 272,000 tokens. Daily totals never choose the tier. Claude input excludes cache categories; cache-write TTL must be known to split five-minute and one-hour writes. Unknown TTL remains unpriced, and conflicting known TTL counters stay unpriced in either encounter order and subsequent replays.

The formula and priced/unpriced token quantities are visible in the UI. Claude streaming messages retain at most eight known cache-write/TTL distributions independently of unknown updates; conflicting smaller distributions, later replays or evidence beyond that bound remain unpriced. Fast/Batch/service tier/region and tool charges are not inferred from absent evidence. Grok/provider spend and remote account totals are outside this local analysis. The existing bundled Codex CLI advertises an `account/usage/read` schema, but this task neither starts its account API nor treats schema availability as a successful account read; its token-only summary cannot be added to local costs without category/model and overlap evidence.

The implementation consulted [CodexBar at commit 6710f07](https://github.com/steipete/CodexBar/tree/6710f07ea155845edee438d99008d6a3162c3a92), specifically its cost pricing/scanner and model-pricing documentation. Reference screenshots and third-party totals are diagnostic clues, not verification that this Mac has complete coverage.

## Verification scope

Tests use synthetic data. Real accounts and local logs are opt-in; source tests and simulator builds do not establish physical notification delivery or complete account-wide token coverage.
