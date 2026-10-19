# Apple builds and internal TestFlight

The repository contains two workflows. Signing credentials are optional for source
checks and unsigned builds. No credentials are included in this repository.

| Workflow / job | Trigger | Result |
| --- | --- | --- |
| Checks / contracts-worker | Push to `main`, pull request, manual | Contracts, localization, Worker checks, release safety tests, dependency audits |
| Checks / ios-simulator | Same | Generated Xcode project, unsigned iOS Simulator app, fresh simulator launch screenshot |
| Checks / macos | Same | Swift tests and an unsigned native macOS app |
| Checks / secrets | Same | Redacted Gitleaks scan of actual checkout and complete fetched Git history |
| Internal TestFlight / ios | Explicit dispatch on protected `main`, approved environment, reviewed immutable tag | Signed internal-only IPA; optional upload; exact Apple processing and existing internal-group readback |
| Internal TestFlight / macos | Explicit dispatch | Stops before credentials, reporting the current sandbox blocker |

`Ammo-iOS-Simulator.zip` cannot install on a physical iPhone. The macOS artifact is
unsigned; distribution signing, notarization, and Mac App Store acceptance are
separate work. Build artifacts expire after seven days. The TestFlight workflow
publishes only a verification receipt and an empty fresh-simulator screenshot,
not signing assets, provisioning profiles, signed IPA files, or raw ASC responses.

## Runner and toolchain costs

The workflows use standard `ubuntu-24.04` and `macos-15` GitHub-hosted runners.
[GitHub states that standard hosted runners are free for public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
Larger runners are billed even for public repositories. These workflows do not
request larger runners, self-hosted runners, paid plans, or additional storage
products. Keep this repository public when relying on public-repository runner
pricing; private-repository allowances are different.

Actions are pinned by full commit SHA. Apple jobs select the Xcode 26.2 installation
listed in the [macos-15 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
XcodeGen 2.43.0 is downloaded from its upstream release and checked against a fixed
SHA-256. The generated `Ammo.xcodeproj` is intentionally excluded from Git; every
Apple job generates it before building. Updating Xcode or runner images requires
a fresh hosted build, not just a successful local build on a different Xcode.

## Protected release setup

Complete this setup only after a maintainer has explicitly approved credential
configuration for this repository. Credential discovery or a local test does not
authorize transferring credentials. Do not put Apple credentials in repository
secrets, code, issue text, logs, receipts, or artifacts.

1. Protect the default `main` branch and require the `Checks` jobs. Releases also
   independently verify a successful **push** run of `Checks` for the exact tagged
   commit, including `contracts-worker`, `ios-simulator`, `macos`, and `secrets`.
2. Add **two active tag rulesets** targeting `refs/tags/testflight/ios/**` without
   exclusions. The creation rule restricts creation and permits only existing trusted
   release maintainers to bypass it. The immutable-tag rule restricts updates and
   deletions and has **no bypass actors**. A bypass applies to its entire ruleset,
   so do not combine all three restrictions in the creation rule. Do not move or
   delete release tags; use a new build number. The runtime guard combines applicable
   rulesets and accepts the exact pattern above, an exact tag ref, or `~ALL`.
   GitHub hides bypass actors from read-only workflow tokens: the owner must verify
   the two bypass lists during setup, without adding an admin token to CI.
3. Create the `testflight-internal` GitHub environment with at least one **existing**
   required reviewer. The owner can approve a manually requested release; disabling
   self-review is optional and must not require granting somebody new access.
   Uncheck **Allow administrators to bypass configured protection rules**. The
   guard requires `can_admins_bypass=false`; missing or enabled bypass stops release.
4. Use the environment's custom deployment branch policy to allow only the exact
   default branch (`main`, type **branch**). Do not allow tags or other branches.
   This is the boundary that prevents a modified workflow on another branch/tag
   from obtaining credentials. The release workflow is manual-only and comes from
   the protected default branch, never from a tag push.
5. After approval, configure the environment variables and secrets below, using
   already authorized secure sources. Set `TESTFLIGHT_ENABLED=true` only when the
   signing identities, profiles, app, and internal test group have been checked.

The preflight reads environment protection and tag rules through GitHub's API.
If these read-only checks are unavailable or return unexpected data, it stops.
Workflow token permissions are `contents: read` and `actions: read`; no GitHub
write permission is needed.

The release workflow has only `workflow_dispatch`; it has no tag-push or
`workflow_run` trigger. Dispatch it on `main` and pass the immutable tag as an
input. Checking out the selected commit does not change the run's `GITHUB_REF`,
so the environment's main-only rule remains consistent. A tag push alone does
not start a release. After dispatch and approval, the selected build/sign/upload/
readback steps run automatically. Do not add a tag trigger without redesigning
both the trusted-ref guard and the environment policy.

The public PR jobs stay on unsigned GitHub-hosted runners. Do not route them to a
Mac containing existing signing assets. The CI signing importer requires
`RUNNER_ENVIRONMENT=github-hosted` and uses temporary assets only; the local release
entry point continues to use the independently authorized local signing flow.

### Environment variables

| Name | Existing value to select |
| --- | --- |
| `TESTFLIGHT_ENABLED` | `true` enables the maintainer's protected internal release policy |
| `APPLE_TEAM_ID` | Existing ten-character Apple developer team |
| `IOS_BUNDLE_ID` | Existing iOS application bundle ID; widget uses `.widgets` |
| `QI_APP_GROUP` | Existing shared app/widget App Group |
| `QI_ICLOUD_CONTAINER` | Existing authorized CloudKit container |
| `ASC_INTERNAL_GROUP_ID` | Existing internal TestFlight group belonging to this app and already containing a tester |

### Environment secrets (names only)

| Name | Purpose / prerequisite |
| --- | --- |
| `ASC_API_KEY_ID` | Existing App Store Connect API key ID |
| `ASC_API_ISSUER_ID` | Existing team API key issuer ID |
| `ASC_API_KEY_P8_B64` | Base64 of the existing `.p8` API private key |
| `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Existing Apple Distribution identity exported as password-protected PKCS#12, including its matching private key |
| `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for that PKCS#12 identity |
| `IOS_APP_PROFILE_BASE64` | Existing App Store distribution provisioning profile for the iOS app |
| `IOS_WIDGET_PROFILE_BASE64` | Existing App Store distribution provisioning profile for its widget |

Some secure sources call the `.p8` value `ASC_API_PRIVATE_KEY_BASE64`; map that
existing alias to `ASC_API_KEY_P8_B64` only during the separately approved setup.
Development identities are not used. A new temporary keychain password is generated
inside each ephemeral runner, so no persistent keychain password needs transferring.
Provisioning profiles are a separate prerequisite from certificates/API credentials.
They must match the team, exact bundle IDs, capabilities, and distribution identity,
be unexpired, and be App Store profiles rather than development/ad hoc profiles.

The workflow imports existing assets into a temporary keychain and deletes that
keychain, the exact profiles it installed, and the `.p8` file in an `always()` cleanup
step. No automatic provisioning flag is passed to Xcode. It never creates keys,
certificates, profiles, bundle IDs, groups, users, or invitations.

## iOS release procedure

1. Merge the reviewed source and wait for all four `Checks` jobs on that commit.
2. Check both processed builds and upload records in App Store Connect, then choose
   an unused build number. Do not reuse a number from a local release or an upload
   with an uncertain outcome. Create an annotated tag whose version equals
   `MARKETING_VERSION` in `project.yml`:

   ```sh
   # Replace VERSION, BUILD and COMMIT with verified release values first.
   git tag -a testflight/ios/vVERSION-bBUILD -m 'Internal TestFlight VERSION (BUILD)' COMMIT
   git push origin refs/tags/testflight/ios/vVERSION-bBUILD
   ```

3. Dispatch **Internal TestFlight** on `main`, choose `ios`, and supply the exact tag.
   Leave `publish=false` for a signing/archive/export rehearsal. Choose `publish=true`
   to authorize the automated upload and linkage to the configured existing internal
   group. Approve the protected environment using an existing authorized reviewer.

   ```sh
   gh workflow run testflight-internal.yml --ref main \
     -f release_tag=testflight/ios/vVERSION-bBUILD -f platform=ios -F publish=true
   ```

The pipeline checks the tag object, main ancestry, version, full CI outcome, and
environment restrictions before secrets are used, and rechecks immediately before
upload. Its concurrency key is the immutable tag. The numeric tag suffix supplies
the build number, so a rerun cannot silently select a different Apple build.

The pipeline generates an unsigned simulator build, installs and launches it in a
new simulator, checks the process after startup, and captures a screenshot. This
is a **launch smoke test**, not evidence that providers, APNs, physical devices,
accessibility, or complete user flows have been exercised.

For signing, an ignored XcodeGen overlay sets manual distribution signing and the
distinct existing profile for each app/widget target. The original
`scripts/testflight-ios.mjs` still performs archive/export, exact signed-bundle
verification, IPA hashing, and `release_preflight.py` artifact-bound evidence gates.
Its new explicit manual-export option leaves the local automatic-signing default
unchanged. CI evidence records only observed automation and the configured owner
release policy; it does not invent a human QA signoff.

Both prepare and upload verify the exported app and widget's signed CloudKit
container, `CloudKit` service and `Production` environment against the selected
container and their embedded provisioning profiles. Runtime Info.plist container
values must match as well. The app also requires `production` APNs in its signature,
profile and runtime configuration; the widget does not require an APNs entitlement.
Profile authorization may contain multiple allowed values or `*`, while the final
signature must contain the concrete production values. These checks use decoded
profile data without logging it and do not create or change Apple capabilities.

The CI ASC adapter supports only the commands required by that release script.
It uses Apple API JWT authentication and Xcode's `altool` for upload. Both the gate
and the final upload adapter reject an existing exact build **or upload record**
for the app, iOS platform, marketing version and build number. Upload records are
fully paginated: an accepted upload can exist before a processed build appears.
Every existing upload state, including failed or unknown states, stops automatic
upload; inspect Apple state and select a new build number. These read checks do not
reserve a build number against another publisher, so avoid concurrent local/CI
releases for the same version/build. Upload is never automatically retried.
After Apple processing, it verifies `VALID` and `INTERNAL_ONLY`, attaches the exact
build to the existing internal group if needed, then reads back group linkage and
`IN_BETA_TESTING`. A successful upload command alone is not a successful release.
The receipt binds tag object, commit, app/build IDs, version/build number, IPA hash,
and a hash of the internal group ID. The group ID and tester identifiers are not
published in artifacts. API endpoint shapes were checked against Apple's
[App Store Connect OpenAPI specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip).

If upload times out or Apple processing exceeds the bounded wait, inspect that
exact version/build in App Store Connect before taking further action. An existing
build blocks a rerun from uploading it again. Recover a missing internal-group link
through an authorized maintainer after checking Apple state; do not change the tag
or blindly rerun. Agreement/compliance issues stop the workflow for a maintainer.
The workflow never accepts legal agreements, requests external beta review, or
submits/releases an App Store version.

## macOS TestFlight boundary

`AmmoDesktop` is currently **unsandboxed** so that it can read locally selected
provider credential/configuration files. The native macOS compile job is useful
today. Mac TestFlight distribution is not ready: it needs a separately designed and
tested sandbox-compatible target and an existing Mac App Store app/profile/signing
configuration, including the distribution installer identity for a signed `.pkg`.
Enabling the entitlement mechanically would change the app's file access behavior.

[Apple's App Sandbox documentation](https://developer.apple.com/documentation/security/app-sandbox)
describes the sandbox requirement for Mac App Store distribution. The macOS release
selection therefore fails before it requests the environment or reads credentials.
There is no hidden iOS-as-Mac substitute and no unverified macOS upload command.
Once that product/signing work is approved and verified, add a separate macOS lane
with `generic/platform=macOS`, the `AmmoDesktop` scheme, manual Mac App Store export,
signed `.pkg` verification, `MAC_OS` ASC selectors, and the same exact-build internal
readback. It must preserve the existing desktop app's intended functionality.

## Validation status

Local syntax, helper regression tests, workflow `actionlint`, XcodeGen overlay
generation, and public-source scanning can validate this implementation without
credentials. They do not prove a hosted CI run, distribution signing, App Store
Connect upload, or TestFlight availability. Those stages require an actual protected
run and its exact Apple readback. No secret transfer or TestFlight execution is
performed merely by adding these workflow files.
