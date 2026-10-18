# Ammo Agent Usage

Ammo is a macOS quota monitor with an optional iPhone companion, widgets,
Live Activities, CLI and MCP access. Each provider/account keeps its own quota
windows, units, freshness and reset times. The Cloudflare Worker can be self-hosted.

**Developer Preview:** source availability does not imply that every provider,
physical device or background delivery scenario has been verified. See
[release readiness](docs/open-source-release.md) and [privacy](PRIVACY.md).

## Build locally

Requires an Apple Silicon Mac, Xcode 26.2+/Swift 6.2+ (deployment targets: macOS 14 and
iOS 17), XcodeGen 2.43+, Node 22+, and Python 3.11+. Tested tool versions are in
`toolchain.json`; Swift, Node and Python dependencies have lock files.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/requirements.lock.txt
npm ci --ignore-scripts
npm --prefix workers/lite ci
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
swift run --disable-sandbox AmmoMac --fixture contracts/fixtures/01-fresh.json
```

The fixture is synthetic. A normal launch does not grant provider access: choose
an account and connect explicitly. Provider credentials stay on the collecting Mac.
See [providers](packages/QuotaProviders/README.md) for supported authentication and
quota semantics. API availability and account entitlements can change upstream.

For iPhone, run `xcodegen generate` and open `Ammo.xcodeproj`. Simulator builds do
not need your Apple signing identity. For signed builds, create the ignored
`config/Signing.local.xcconfig` with your own `DEVELOPMENT_TEAM`,
`QI_BUNDLE_PREFIX`, `QI_APP_GROUP` and `QI_ICLOUD_CONTAINER`. The shared defaults
use `org.example.ammo`. Provision CloudKit, App Groups and APNs for your own IDs.
Do not reuse someone else's signing account or containers.

Cloud sync defaults to self-hosting with an explicitly entered HTTPS endpoint.
An app distributor can optionally set `QI_HOSTED_SYNC_ENDPOINT` in its ignored
signing configuration to display a hosted-service choice; there is no built-in
maintainer server. In an xcconfig, escape URL slashes (for example,
`https:/$()/sync.example.invalid`) so `//` is not parsed as a comment.
CloudKit reads the configured container from the generated app Info.plist and
reports a configuration error when it is missing.

## Balances and budgets

The Mac and iPhone overview separates prepaid balances, billing-period usage,
free allowances and quota windows. Connect OpenRouter, fal, Cloudflare, Vercel
or Replit Enterprise from the Mac. Open a metric to configure low-balance or
spending thresholds; Mac notifications are opt-in and require Ammo to be running.
Amounts keep their currency and scope; they are never combined into one wallet.
See [setup and limitations](docs/17-platform-billing.md).

## Optional services

- [Self-hosted Worker](workers/lite/README.md): encrypted snapshot sync, pairing,
  explicit quota sharing and optional APNs. No deployment runs during tests.
- [CLI](executables/qi/README.md) and [MCP](executables/qi-mcp/README.md): read local
  snapshots; remote HTTP MCP is a separate opt-in with a revocable read token.
- iCloud uses your signed app's private CloudKit container. Background refresh
  and Live Activity presentation are scheduled by iOS, not guaranteed intervals.

## License

Project code is licensed under [Apache-2.0](LICENSE). Third-party materials retain
their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

WorkBuddy/CodeBuddy, ZCode, fal, Cloudflare, Vercel and Replit use original letter
placeholders, not official logos or a claim of brand authorization. They are drawn
by `scripts/ci/generate-provider-placeholders.py` without external images or fonts.
Provider names remain readable in the interface; Ammo's own App icon is unchanged.

## Contribute and distribute

Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[PRIVACY.md](PRIVACY.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
This is the independent maintenance repository for Ammo. Its source provenance
is recorded in [SOURCE.md](SOURCE.md). Release source archives use the explicit
allowlist in `scripts/export_public.py`; local account data, signing material and
private QA evidence must stay out of Git.

GitHub Actions build the iPhone simulator app and native Mac app separately.
See [Actions and internal TestFlight setup](docs/github-actions.md) for the
signing prerequisites, trusted release triggers and platform limitations.

## Recorded token usage

Opt in from the Mac **Usage** page to analyze local Claude Code and Codex logs,
view day / Monday-based week / month totals, and preview or export a private
thermal-paper receipt. With the updated encrypted Worker, the paired iPhone shows
the same single-Mac aggregate. Unknown sources stay unknown; this is partial local
coverage, not billing. See [counting, privacy, compatibility and limits](docs/18-token-usage.md).
