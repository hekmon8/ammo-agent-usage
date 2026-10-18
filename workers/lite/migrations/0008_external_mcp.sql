-- Independent capability: never usable as a writer or phone bearer.
CREATE TABLE mcp_access (
 workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
 token_hash TEXT NOT NULL UNIQUE,
 source_epoch TEXT NOT NULL,
 expires_at TEXT NOT NULL,
 source_sequence INTEGER NOT NULL DEFAULT 0,
 snapshot_json TEXT,
 captured_at TEXT
);
