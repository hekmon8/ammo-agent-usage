-- Multi-tenant bootstrap: every bootstrap token provisions exactly one
-- workspace. The legacy bootstrap_state singleton (0001) marks the single
-- legacy workspace; every successful BOOTSTRAP_SECRET bootstrap records it,
-- so rotating the legacy secret cannot reopen bootstrap. It blocks only the
-- legacy BOOTSTRAP_SECRET, never BOOTSTRAP_SECRETS tokens.
CREATE TABLE IF NOT EXISTS bootstrap_tenants (
  bootstrap_token_hash TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL UNIQUE,
  completed_at TEXT NOT NULL
);
