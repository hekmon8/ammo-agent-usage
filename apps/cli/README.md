# CLI and MCP

Both executables read the same local public snapshot through `QuotaQuery` and
`QuotaStore`. They do not start a second collector or read provider credentials.
Build them from the repository root with `swift build --disable-sandbox`.

```sh
.build/debug/qi status --json
.build/debug/qi quota list --provider codex
.build/debug/qi quota list --provider codex --account account_work
.build/debug/qi quota get --window codex-primary
.build/debug/qi quota get --window codex-account_work-primary
.build/debug/qi history --window codex-primary --range 24h
.build/debug/qi doctor --redact
.build/debug/qi refresh --wait --timeout 10
```

`doctor` requires `--redact` and returns a health summary of the public snapshot.

Several accounts of one provider (for example a Codex machine login plus a
browser-login profile, or two OpenRouter keys) are separate windows. Every
window carries `providerId`, `accountId` and the user-chosen `accountAlias`;
`quota list --account` and the `quota://providers` resource select and enumerate
them. Window ids name their account (`codex-account-…-primary`); ids from before
accounts were carried (`codex-primary`) still resolve for `quota get` and
`quota_history` while they match exactly one window, otherwise the call fails
with exit code 2 and an ambiguous-id message. Remote MCP windows carry an opaque
`account` tag instead of these local fields.

`refresh` requests the running Mac collector through local IPC. Global options
include `--data-dir <directory>` and `--require-fresh`. Exit codes distinguish
invalid arguments (2), unavailable data or collector (3), stale data (4),
permissions (5), and other failures or timeouts (6).

For an MCP client, start `.build/debug/qi-mcp` or
`.build/debug/qi mcp serve --stdio`. Both use the official Swift MCP SDK and keep
stdout reserved for protocol frames. The standalone executable accepts
`--data-dir <directory>`.

Read-only tools: `quota_list`, `quota_get`, `quota_history`, `quota_health`.
Resources include `quota://snapshot/latest` and `quota://providers`.
See [the client configuration example](../../contracts/examples/mcp-config.example.json).

After building, run `python3 scripts/check_cli_mcp.py` from the repository root
to verify CLI exit codes and MCP initialization, tools, resources and shutdown
against a temporary synthetic snapshot.
