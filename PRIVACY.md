# Data and privacy

Ammo has no built-in analytics or advertising telemetry. Provider endpoints receive
requests necessary to fetch the accounts you connect. Provider credentials are
stored locally in Keychain or an explicitly selected isolated provider profile.

| Mode | Data visible to the service | Local/remote retention and removal |
| --- | --- | --- |
| Local collection / CLI | No Ammo server; provider sees its authenticated API requests | Local snapshots/history remain on the Mac; deleting a connection stops collection but is not a filesystem secure erase |
| Worker snapshot sync | Encrypted snapshot, device/public-key metadata, sequence and request metadata | Paired clients decrypt; revoke a device and rotate keys to deny future access. Operator backups may retain ciphertext |
| iCloud | Private CloudKit records containing encrypted snapshots and sync material | Bound to your iCloud account/container; consult Apple's service terms and remove container data separately |
| APNs monitoring, opt-in | Worker reads window ID, label, remaining percentage, state and timing; Apple receives the push payload | Activity registration expires; ending/revoking monitoring stops future sends. Previously delivered data cannot be recalled |
| HTTP MCP, opt-in | Worker stores a reduced plaintext current quota snapshot, excluding provider credentials and account aliases | Read grants expire after 90 days; disabling or switching service revokes the grant and deletes its current projection after server acknowledgement |
| One-account sharing, opt-in | Worker reads selected quota projection and writer-side account association; recipient sees chosen label and quota fields | Grant lasts until revoked; revocation removes delivery/projection data. A recipient may have retained prior results |
| Widgets | App Group holds a local choice catalog and verified snapshot cache for trusted app extensions | Choice metadata is minimized and cleared when pairing is removed; this is local metadata, not an encrypted network snapshot |

Encryption of the full snapshot does not make the optional plaintext projections
end-to-end encrypted. Self-hosting changes who operates the Worker; it does not
change these data boundaries. A public source license does not grant free access
to the maintainer's hosted service or provider APIs.

The repository ships synthetic fixtures. Keep real account screenshots, QR codes,
TestFlight tester lists, device records and signing material out of public issues,
commits and releases. Diagnostic errors should contain fixed categories rather
than raw provider responses or tokens.

### Opt-in token-usage analysis

When explicitly enabled in the Mac Usage page, Ammo reads local Claude Code and
Codex JSONL logs for numeric token counters. Raw lines are transient during
analysis; conversation content, project paths, request/session IDs and account
identities are excluded from persisted daily aggregates and exported receipts.
The latest 400 days of day/agent/category aggregates are stored locally with
private-file permissions. If encrypted Worker sync is enabled, the aggregate is
sent as a separate end-to-end encrypted single-source snapshot to the paired
phone. iCloud-only sync does not include usage. Turning analysis off stops reads
and queues an empty disabled-source observation for sync; an offline phone can
retain the prior timestamped observation until it reconnects. Exported images are
shared only through the user's save/share action and remain under their control.
