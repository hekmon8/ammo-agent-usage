-- Shared across Worker isolates; the JWT remains encrypted with DELIVERY_ENCRYPTION_KEY.
CREATE TABLE apns_provider_token_cache (
  key_fingerprint TEXT PRIMARY KEY,
  token_ciphertext TEXT,
  issued_at_ms INTEGER,
  lease_id TEXT,
  lease_until_ms INTEGER
);
