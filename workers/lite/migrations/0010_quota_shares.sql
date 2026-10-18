-- Independent, per-recipient capability. No snapshot envelope or pairing credential is stored here.
CREATE TABLE quota_shares (
  share_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
  writer_device_id TEXT NOT NULL REFERENCES devices(device_id),
  connection_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  label TEXT NOT NULL,
  invite_secret_hash TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'approved', 'revoked')),
  claim_id TEXT UNIQUE,
  claim_token_hash TEXT UNIQUE,
  claimed_at TEXT,
  recipient_name TEXT,
  verification_code TEXT,
  viewer_token_hash TEXT UNIQUE,
  viewer_token_ciphertext TEXT,
  delivery_expires_at TEXT,
  captured_at TEXT,
  windows_json TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  approved_at TEXT,
  revoked_at TEXT
);
CREATE INDEX quota_shares_workspace_idx ON quota_shares(workspace_id, created_at);
