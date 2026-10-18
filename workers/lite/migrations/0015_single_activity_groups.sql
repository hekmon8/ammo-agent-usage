-- v2 is isolated from v1 tokens and queues. Retired IDs and commands are tombstones.
CREATE TABLE live_activity_display_state (
 workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, display_revision INTEGER NOT NULL DEFAULT 0,
 group_id TEXT, stopped INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(workspace_id,device_id)
);
CREATE TABLE live_activity_groups (
 group_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, device_id TEXT NOT NULL,
 source_device_id TEXT NOT NULL, source_epoch TEXT NOT NULL, window_ids TEXT NOT NULL,
 token_ciphertext TEXT NOT NULL, environment TEXT NOT NULL, ends_at TEXT NOT NULL, coverage_expires_at TEXT NOT NULL,
 registration_revision INTEGER NOT NULL, display_revision INTEGER NOT NULL,
 bundle_revision INTEGER NOT NULL DEFAULT 1, pending_revision INTEGER DEFAULT 1,
 projection_consent INTEGER NOT NULL DEFAULT 1 CHECK(projection_consent IN (0,1)),
 retired INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0,
 lease_id TEXT, lease_until TEXT, claimed_revision INTEGER, claimed_json TEXT,
 last_event_timestamp INTEGER NOT NULL DEFAULT 0, last_sent_at TEXT, backoff_until TEXT
);
CREATE TABLE live_activity_group_windows (
 group_id TEXT NOT NULL REFERENCES live_activity_groups(group_id), slot INTEGER NOT NULL CHECK(slot IN (0,1)),
 window_id TEXT NOT NULL, PRIMARY KEY(group_id,slot), UNIQUE(group_id,window_id)
);
CREATE TABLE live_activity_commands (
 workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, command_id TEXT NOT NULL, request_hash TEXT NOT NULL,
 operation_id TEXT NOT NULL UNIQUE, display_revision INTEGER NOT NULL, registration_revision INTEGER,
 group_id TEXT, PRIMARY KEY(workspace_id,device_id,command_id)
);
CREATE INDEX live_activity_groups_owner ON live_activity_groups(workspace_id,device_id,retired);
CREATE INDEX live_activity_windows_lookup ON live_activity_group_windows(window_id,group_id);
CREATE INDEX live_activity_groups_queue ON live_activity_groups(retired,disabled,pending_revision);
CREATE TRIGGER live_projection_v2_insert AFTER INSERT ON live_projections BEGIN
 UPDATE live_activity_groups SET bundle_revision=bundle_revision+1,pending_revision=bundle_revision+1
 WHERE retired=0 AND disabled=0 AND workspace_id=NEW.workspace_id AND source_epoch=NEW.source_epoch
 AND EXISTS(SELECT 1 FROM live_activity_group_windows m WHERE m.group_id=live_activity_groups.group_id AND m.window_id=NEW.window_id);
END;
CREATE TRIGGER live_projection_v2_update AFTER UPDATE ON live_projections BEGIN
 UPDATE live_activity_groups SET bundle_revision=bundle_revision+1,pending_revision=bundle_revision+1
 WHERE retired=0 AND disabled=0 AND workspace_id=NEW.workspace_id AND source_epoch=NEW.source_epoch
 AND EXISTS(SELECT 1 FROM live_activity_group_windows m WHERE m.group_id=live_activity_groups.group_id AND m.window_id=NEW.window_id);
END;
CREATE TRIGGER live_projection_v2_delete AFTER DELETE ON live_projections BEGIN
 UPDATE live_activity_groups SET bundle_revision=bundle_revision+1,pending_revision=bundle_revision+1
 WHERE retired=0 AND disabled=0 AND workspace_id=OLD.workspace_id AND source_epoch=OLD.source_epoch
 AND EXISTS(SELECT 1 FROM live_activity_group_windows m WHERE m.group_id=live_activity_groups.group_id AND m.window_id=OLD.window_id);
END;
