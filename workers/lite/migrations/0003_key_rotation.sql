CREATE TABLE IF NOT EXISTS key_rotation_stages (
  rotation_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  old_source_epoch TEXT NOT NULL,
  new_source_epoch TEXT NOT NULL,
  new_source_public_key TEXT NOT NULL,
  key_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS key_rotation_stage_wraps (
  rotation_id TEXT NOT NULL REFERENCES key_rotation_stages(rotation_id),
  device_id TEXT NOT NULL,
  wrapped_snapshot_key TEXT NOT NULL,
  PRIMARY KEY(rotation_id, device_id)
);
CREATE TABLE IF NOT EXISTS key_rotation_revisions (
  server_revision INTEGER PRIMARY KEY AUTOINCREMENT,
  rotation_id TEXT NOT NULL UNIQUE,
  workspace_id TEXT NOT NULL,
  source_epoch TEXT NOT NULL,
  key_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS device_key_wraps (
  workspace_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  source_epoch TEXT NOT NULL,
  key_id TEXT NOT NULL,
  wrapped_snapshot_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(workspace_id, device_id, source_epoch, key_id)
);
CREATE INDEX IF NOT EXISTS device_key_wraps_device_idx ON device_key_wraps(workspace_id, device_id, source_epoch);
