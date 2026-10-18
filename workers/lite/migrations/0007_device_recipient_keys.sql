ALTER TABLE devices ADD COLUMN recipient_public_key TEXT;
ALTER TABLE key_rotation_revisions ADD COLUMN rotation_message_hash TEXT;
ALTER TABLE key_rotation_revisions ADD COLUMN rotation_signature TEXT;
