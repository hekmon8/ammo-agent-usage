CREATE TABLE IF NOT EXISTS snapshots (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
  source_device_id TEXT NOT NULL,
  source_epoch TEXT NOT NULL,
  source_sequence INTEGER NOT NULL CHECK (source_sequence >= 1 AND source_sequence <= 9007199254740991),
  content_hash TEXT NOT NULL,
  envelope_json TEXT NOT NULL,
  server_revision INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS snapshot_receipts (
  server_revision INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
  source_epoch TEXT NOT NULL,
  source_sequence INTEGER NOT NULL CHECK (source_sequence >= 1 AND source_sequence <= 9007199254740991),
  content_hash TEXT NOT NULL,
  received_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  UNIQUE(workspace_id, source_epoch, source_sequence)
);
CREATE INDEX IF NOT EXISTS snapshot_receipts_expiry_idx ON snapshot_receipts(expires_at);
