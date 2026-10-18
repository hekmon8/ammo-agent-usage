ALTER TABLE key_rotation_revisions ADD COLUMN old_source_epoch TEXT;
ALTER TABLE key_rotation_revisions ADD COLUMN new_source_public_key TEXT;
ALTER TABLE key_rotation_revisions ADD COLUMN trust_signature TEXT;
