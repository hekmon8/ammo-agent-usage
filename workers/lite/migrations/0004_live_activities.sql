CREATE TABLE IF NOT EXISTS live_activities (
  activity_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  window_id TEXT NOT NULL,
  token_ciphertext TEXT NOT NULL,
  environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
  ends_at TEXT NOT NULL,
  projection_consent INTEGER NOT NULL CHECK(projection_consent IN (0,1)),
  last_sent_at TEXT,
  backoff_until TEXT,
  disabled_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS live_activities_delivery_idx ON live_activities(workspace_id, window_id, ends_at, disabled_at);
CREATE TABLE IF NOT EXISTS live_projections (
  workspace_id TEXT NOT NULL,
  window_id TEXT NOT NULL,
  source_epoch TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  projection_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(workspace_id, window_id)
);
