-- One encrypted cumulative usage aggregate per workspace, never a token ledger.
-- Keep its source/sequence/hash watermark after ciphertext expiry to reject replay.
CREATE TABLE IF NOT EXISTS usage_snapshots (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
  source_device_id TEXT NOT NULL,
  source_epoch TEXT NOT NULL,
  source_sequence INTEGER NOT NULL CHECK (source_sequence >= 1 AND source_sequence <= 9007199254740991),
  content_hash TEXT NOT NULL,
  envelope_json TEXT,
  server_revision INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
