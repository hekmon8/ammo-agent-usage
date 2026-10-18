# Source and binary releases

The public repository is independent and starts with one root commit. Development
history is never pushed or mirrored. Source export and signed distribution have
separate acceptance criteria.

## Source export

1. Finish the required checks in CONTRIBUTING.md and review the exact commit.
2. Confirm the project license, third-party terms and ownership of shipped assets.
3. Run `python3 scripts/export_public.py --output /absolute/new/directory`.
   The destination must not exist. Only allowlisted tracked files are copied;
   no `.git`, internal QA, screenshots, videos, design boards, local signing files,
   reference test leftovers, build output or deployment receipts are copied.
4. Run Gitleaks against that directory and inspect `PUBLIC_MANIFEST.json`.
5. In a clean environment install pinned dependencies and run the public checks.
6. Initialize a new Git repository there; its first commit has no parent. Create
   the separate public remote only after its name, license and exact contents are
   confirmed. Never add the private repository as a public upstream or push --mirror.

The exporter produces source only. It does not create a remote, publish, deploy,
rewrite history, or label a binary release as validated.

## CI and release identity

Pull requests run checks with read-only permissions and no publishing credentials.
CI performs static/contract tests and local ephemeral Worker tests. Maintainers
record the tested full commit SHA. Signed release artifacts must come from a
protected immutable version tag pointing to the verified commit; verify the IPA
identity, entitlements and signature again immediately before upload.

`scripts/testflight-ios.mjs --dry-run` is local and requires explicit signing
configuration but no ASC credential. This script is restricted to internal
TestFlight exports. `--prepare` builds and validates an IPA; `--upload` checks
the clean commit, expected app, artifact hash, signature, internal-only export
options and internal TestFlight evidence before uploading. No private helper
library is required. An internal TestFlight upload is not a formal binary
release and does not clear the physical release gates below.

## Internal TestFlight evidence

After the source commit, place private receipts in ignored
`.release/internal-testflight-gates.json` and evidence files under `.release/`.
The JSON requires `profile: "internal-testflight"`, an `artifact` object with
`appID`, `bundleID`, `version`, `buildNumber` and `ipaSha256` matching the
prepared IPA, and exactly these four gate IDs:

- `TF-INTERNAL-owner-authorization`: record the owner's authorization for
  internal TestFlight distribution of this build.
- `TF-INTERNAL-signed-ipa`: record the verified IPA identity, signature,
  entitlements, privacy manifest and hash.
- `TF-INTERNAL-simulator-smoke`: record the simulator flow exercised for this
  source commit and link its local capture. This is simulator evidence only.
- `TF-INTERNAL-tester-group`: record the existing ASC internal group, tester
  population and intended build association. Read back the association after
  upload; a successful upload alone is not tester delivery.

Each entry has the same evidence, verifier and timestamp fields as the formal
gates below. Each distinct evidence file must be a JSON object with `gateID`,
the exact full `commit`, the same `artifact` object, and a nonempty `statement`
describing what was verified. All paths must resolve beneath `.release/`.
The preflight checks evidence integrity, exact commit and IPA identity. It
cannot independently prove a human observation. Use
`python3 scripts/release_preflight.py --profile internal-testflight --app-id ...
--bundle-id ... --version ... --build-number ... --ipa-sha256 ...` to inspect
the gate before upload. Internal testing does not assert physical APNs,
display/Spaces, device matrix, accessibility or duration results, and it does
not authorize external TestFlight or App Store distribution.

## Physical release evidence

For a formal release, store current gate receipts in ignored `.release/gates.json` after
committing source; this avoids a self-referential commit hash. The preflight requires gate-specific,
nonempty evidence, a SHA-256 hash, an exact commit and a verifier/time record.
File existence alone cannot prove a device test or grant release permission.

APNs delivery on a physical device, displays/Spaces, the iOS device matrix,
accessibility and long-duration performance still require measured evidence.
Do not mark them passed based on simulator builds or unit tests. Public source
previews do not promise those guarantees. Public exporters omit internal gates;
maintainers must provide their own evidence before using the upload script.

## Deployment and recovery

Use a separate staging Worker, D1 database and credentials for validation. Apply
migrations to staging and exercise auth/revocation/retry tests before promotion.
Production deployment/migrations and signing uploads are explicit operations.
Keep a known-good deployment version and database recovery plan. APNs updates use
one bulk secret submission; keep the previous complete secret set in recoverable
private storage, since service-side failure and rollback still need operator action.


Each entry in `.release/gates.json` requires `id`, `verified: true`, `commit`
(the full clean source SHA), `evidence` (relative path under `.release/`),
`sha256` (of that evidence), `verifier` and `verifiedAt` (UTC ISO timestamp).
The evidence text must identify its gate ID. Obtain the complete required ID set
from `REQUIRED` in `scripts/release_preflight.py`. Evidence is private release
metadata, generated after the source commit and never added to Git. Successful
preflight validates integrity and binding, not the truth of human observations.
