ALTER TABLE mcp_access ADD COLUMN never_expires INTEGER NOT NULL DEFAULT 0 CHECK (never_expires IN (0, 1));
ALTER TABLE mcp_access ADD COLUMN received_shares_json TEXT;
