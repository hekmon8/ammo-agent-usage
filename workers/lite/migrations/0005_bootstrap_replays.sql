CREATE TABLE IF NOT EXISTS bootstrap_replays (
  request_id TEXT PRIMARY KEY,
  bootstrap_token_hash TEXT NOT NULL,
  device_name TEXT NOT NULL,
  source_public_key TEXT NOT NULL,
  workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  source_epoch TEXT NOT NULL,
  response_ciphertext TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bootstrap_replays_expiry_idx ON bootstrap_replays(expires_at);
