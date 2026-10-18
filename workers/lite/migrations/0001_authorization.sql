CREATE TABLE IF NOT EXISTS bootstrap_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  completed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workspaces (
  workspace_id TEXT PRIMARY KEY,
  writer_device_id TEXT NOT NULL UNIQUE,
  source_epoch TEXT NOT NULL,
  source_public_key TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
  role TEXT NOT NULL CHECK (role IN ('writer', 'viewer')),
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_workspace_idx ON devices(workspace_id, revoked_at);

CREATE TABLE IF NOT EXISTS pairings (
  pairing_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
  creator_device_id TEXT NOT NULL REFERENCES devices(device_id),
  source_epoch TEXT NOT NULL,
  pairing_secret_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'approved', 'consumed', 'rejected')),
  claim_id TEXT UNIQUE,
  claim_token_hash TEXT,
  recipient_name TEXT,
  recipient_public_key TEXT,
  approved_device_id TEXT REFERENCES devices(device_id) DEFERRABLE INITIALLY DEFERRED,
  delivery_ciphertext TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  approved_at TEXT,
  consumed_at TEXT
);
CREATE INDEX IF NOT EXISTS pairings_workspace_idx ON pairings(workspace_id, expires_at);
CREATE INDEX IF NOT EXISTS pairings_claim_idx ON pairings(pairing_id, claim_id, claim_token_hash);

CREATE TABLE IF NOT EXISTS rate_limits (
  bucket TEXT PRIMARY KEY,
  window_started_at INTEGER NOT NULL,
  count INTEGER NOT NULL
);
