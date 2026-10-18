-- Balance/budget alerts pushed as standard APNs alerts to consented iPhones.
-- The iPhone (viewer) registers its system push token; the Mac (writer) owns
-- the alert rules and the relay switch. Tokens are encrypted at rest like
-- Live Activity tokens; plaintext never reaches storage.
CREATE TABLE alert_push_tokens (
  device_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  token_ciphertext TEXT NOT NULL,
  environment TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (device_id, workspace_id)
);
CREATE INDEX alert_push_tokens_workspace_idx ON alert_push_tokens(workspace_id);

-- Writer-controlled relay switch per workspace. The Mac may only turn alert
-- relaying on; the iPhone always keeps its own local authorization switch.
CREATE TABLE alert_settings (
  workspace_id TEXT PRIMARY KEY,
  phone_alerts_enabled INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

-- Deduplication ledger so a retried alert POST cannot spam the phone. Rows are
-- pruned by the cron handler after 24 hours.
CREATE TABLE alert_push_log (
  alert_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  PRIMARY KEY (alert_id, workspace_id)
);
