-- Keep the latest consented projection pending until APNs accepts it or the activity expires.
ALTER TABLE live_activities ADD COLUMN pending_sequence INTEGER;
ALTER TABLE live_activities ADD COLUMN dispatch_lease TEXT;
ALTER TABLE live_activities ADD COLUMN dispatching_until TEXT;
CREATE INDEX live_activities_pending_idx ON live_activities(pending_sequence, backoff_until, dispatching_until);

-- Existing installations may have admitted a projection before APNs failed.
-- Requeue only an active, consented viewer whose current-epoch projection is
-- newer than the last accepted push. The scheduler will retry after upgrade.
UPDATE live_activities SET pending_sequence = (
  SELECT projection.sequence FROM live_projections AS projection
  JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch
  WHERE projection.workspace_id = live_activities.workspace_id
    AND projection.window_id = live_activities.window_id
    AND (live_activities.last_sent_at IS NULL OR live_activities.last_sent_at < projection.updated_at)
)
WHERE projection_consent = 1
  AND disabled_at IS NULL
  AND ends_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  AND EXISTS (SELECT 1 FROM devices WHERE device_id = live_activities.device_id
    AND workspace_id = live_activities.workspace_id AND role = 'viewer' AND revoked_at IS NULL)
  AND EXISTS (SELECT 1 FROM live_projections AS projection
    JOIN workspaces AS workspace ON workspace.workspace_id = projection.workspace_id AND workspace.source_epoch = projection.source_epoch
    WHERE projection.workspace_id = live_activities.workspace_id
      AND projection.window_id = live_activities.window_id
      AND (live_activities.last_sent_at IS NULL OR live_activities.last_sent_at < projection.updated_at));
