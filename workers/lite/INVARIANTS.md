# Authorization invariants

| Rule | Database boundary |
| --- | --- |
| A device token names no tenant | Authentication resolves its workspace and role from a SHA-256 hash; every resource query constrains that workspace. |
| Revocation is immediate | Every device-token lookup requires `revoked_at IS NULL`; no cached authorization result exists. |
| A pairing has one claimant | `pending -> claimed` is one conditional SQL update, so only its successful writer receives a claim capability. |
| A claim capability is scoped and temporary | Result and acknowledgement both match `pairing_id`, `claim_id`, hashed claim token, and unexpired state. |
| Delivery is one-way | Approval encrypts temporary delivery data with the Worker secret; acknowledgement conditionally clears it while moving to `consumed`. |
| Bootstrap is explicitly bounded | It requires both enabled configuration and the bootstrap secret, and D1 records a single completed bootstrap. |
| Snapshot bytes are source-authenticated | Exact v1 header plus raw nonce, ciphertext and tag are SHA-256 checked and Ed25519 verified against the workspace-pinned source key before any D1 write. |
| Snapshot ordering survives retry | A conditional D1 batch accepts only a live writer's higher sequence for the pinned epoch; a seven-day receipt makes same-sequence/same-hash retries return their original receipt. |
| Cache validation cannot bypass revocation | GET authenticates an active viewer before snapshot lookup or ETag/304 handling. |
