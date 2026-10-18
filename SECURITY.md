# Security policy

This project is a Developer Preview. Security fixes target the current development
branch; older preview builds have no maintenance guarantee.

Report vulnerabilities through the public repository's **Security → Report a
vulnerability** private reporting channel. The maintainer must enable that channel
before publication. If it is unavailable, request a private reporting channel
without posting vulnerability details, tokens, account data or a working exploit
in a public issue. There is no guaranteed response-time SLA.

Include affected version, prerequisites, impact and a synthetic reproduction.
Do not test against the hosted service or other users' accounts without permission.

Trust boundaries: the Mac owns provider credentials; snapshot keys stay with paired
clients; the Worker authenticates device and resource grants. Optional APNs,
remote MCP and account sharing expose deliberately reduced plaintext data as
explained in PRIVACY.md. Revocation requires a successful server response.
